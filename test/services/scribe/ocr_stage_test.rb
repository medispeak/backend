# OcrStage tests against stubbed HTTP (WebMock). No DB.
# Standalone: `ruby -Itest test/services/scribe/ocr_stage_test.rb`
#
# The stage is where OCR's completeness contract lives. An adapter may or may
# not notice a truncated response; the stage must, for every provider, because a
# half-transcribed lab report persisted as THE transcript is the failure mode
# that reaches a clinician looking exactly like a success.
require "minitest/autorun"
require "webmock/minitest"
require "openai"
# Bundled, not default, since Ruby 3.4 — Rails requires it for us, a standalone
# run does not, and the adapters base64 every document.
require "base64"
# Both adapters' #ocr reach for blank?/presence when deciding whether a 200
# actually carried text, so the standalone run needs those core_ext too.
require "active_support"
require "active_support/core_ext/object/blank"

unless defined?(Rails)
  llm = File.expand_path("../../../app/services/llm", __dir__)
  %w[usage result error timeout rate_limited bad_response config adapter
     adapters/anthropic adapters/openai_compatible registry caller].each { |f| require_relative "#{llm}/#{f}" }
  require_relative File.expand_path("../../../app/services/scribe/ocr_stage", __dir__)
end

class OcrStageTest < Minitest::Test
  MESSAGES_URL = "https://api.anthropic.com/v1/messages".freeze
  CHAT_URL = "https://api.openai.com/v1/chat/completions".freeze

  def setup; WebMock.disable_net_connect!; end
  def teardown; WebMock.reset!; end

  def anthropic_config(fallback: nil)
    Llm::Config.new(provider_kind: :anthropic, api_model_id: "claude-3-5-sonnet-latest",
                    base_url: "https://api.anthropic.com", api_key: "sk-ant-test",
                    fallback: fallback)
  end

  def openai_config
    Llm::Config.new(provider_kind: :openai_compatible, api_model_id: "gpt-4o-mini",
                    base_url: "https://api.openai.com/", api_key: "sk-test")
  end

  def anthropic_body(text: "Hemoglobin | 13.5 g/dL", stop: "end_turn")
    { status: 200, headers: { "Content-Type" => "application/json" },
      body: { id: "msg_1", type: "message", role: "assistant", stop_reason: stop,
              content: [ { type: "text", text: text } ],
              usage: { input_tokens: 900, output_tokens: 120 } }.to_json }
  end

  def openai_body(text: "Hemoglobin | 13.5 g/dL", finish: "stop")
    { status: 200, headers: { "Content-Type" => "application/json" },
      body: { choices: [ { message: { content: text }, finish_reason: finish } ],
              usage: { prompt_tokens: 900, completion_tokens: 120 } }.to_json }
  end

  def documents
    [ { data: "%PDF-1.4 bytes", content_type: "application/pdf", filename: "cbc.pdf" } ]
  end

  # ── completeness ─────────────────────────────────────────────────────────

  def test_anthropic_truncation_raises_instead_of_persisting_a_partial_report
    # The regression this guard exists for: Anthropic answers 200 with real text
    # and stop_reason "max_tokens". The adapter is happy (the text is not blank),
    # so before the stage guard this half-report became the clinical transcript.
    stub_request(:post, MESSAGES_URL).to_return(anthropic_body(text: "Hemoglobin | 13.5", stop: "max_tokens"))

    error = assert_raises(Llm::BadResponse) do
      Scribe::OcrStage.new(config: anthropic_config).call(documents, pages: 12)
    end
    assert_match(/max_tokens/, error.message)
  end

  def test_openai_truncation_raises
    stub_request(:post, CHAT_URL).to_return(openai_body(finish: "length"))

    assert_raises(Llm::BadResponse) do
      Scribe::OcrStage.new(config: openai_config).call(documents, pages: 12)
    end
  end

  def test_end_turn_and_stop_both_count_as_complete
    stub_request(:post, MESSAGES_URL).to_return(anthropic_body(stop: "end_turn"))
    assert_equal "Hemoglobin | 13.5 g/dL",
                 Scribe::OcrStage.new(config: anthropic_config).call(documents, pages: 2).text

    stub_request(:post, CHAT_URL).to_return(openai_body(finish: "stop"))
    assert_equal "Hemoglobin | 13.5 g/dL",
                 Scribe::OcrStage.new(config: openai_config).call(documents, pages: 2).text
  end

  # BadResponse is one of Llm::Caller::TRANSIENT, so a truncated primary must
  # spend the configured fallback rather than failing the session outright.
  def test_truncation_falls_back_to_the_secondary_provider
    stub_request(:post, MESSAGES_URL).to_return(anthropic_body(stop: "max_tokens"))
    stub_request(:post, CHAT_URL).to_return(openai_body(text: "Full report text"))

    result = Scribe::OcrStage.new(config: anthropic_config(fallback: openai_config))
                             .call(documents, pages: 4)
    assert_equal "Full report text", result.text
    assert_requested :post, CHAT_URL, times: 1
  end

  def test_finish_reason_is_carried_on_the_result
    stub_request(:post, MESSAGES_URL).to_return(anthropic_body(stop: "end_turn"))
    result = Scribe::OcrStage.new(config: anthropic_config).call(documents, pages: 1)
    assert_equal "end_turn", result.finish_reason
  end

  # ── output budget ────────────────────────────────────────────────────────

  def test_max_tokens_scales_with_page_count_not_the_structuring_default
    stub_request(:post, MESSAGES_URL).to_return(anthropic_body)
    Scribe::OcrStage.new(config: anthropic_config).call(documents, pages: 12)

    assert_requested(:post, MESSAGES_URL) do |req|
      JSON.parse(req.body)["max_tokens"] == 12 * Scribe::OcrStage::TOKENS_PER_PAGE
    end
  end

  def test_max_tokens_has_a_floor_for_single_page_and_image_uploads
    stub_request(:post, MESSAGES_URL).to_return(anthropic_body)
    Scribe::OcrStage.new(config: anthropic_config).call(documents, pages: 1)

    assert_requested(:post, MESSAGES_URL) do |req|
      JSON.parse(req.body)["max_tokens"] == Scribe::OcrStage::MIN_MAX_TOKENS
    end
  end

  # A spoofed page count must not turn into an absurd completion request.
  def test_max_tokens_is_capped
    stub_request(:post, MESSAGES_URL).to_return(anthropic_body)
    Scribe::OcrStage.new(config: anthropic_config).call(documents, pages: 100_000)

    assert_requested(:post, MESSAGES_URL) do |req|
      JSON.parse(req.body)["max_tokens"] == Scribe::OcrStage::MAX_MAX_TOKENS
    end
  end

  def test_openai_ocr_sends_the_budget_too
    stub_request(:post, CHAT_URL).to_return(openai_body)
    Scribe::OcrStage.new(config: openai_config).call(documents, pages: 6)

    assert_requested(:post, CHAT_URL) do |req|
      JSON.parse(req.body)["max_tokens"] == 6 * Scribe::OcrStage::TOKENS_PER_PAGE
    end
  end

  # ── page count on usage ──────────────────────────────────────────────────

  def test_pages_are_grafted_onto_provider_usage_without_clobbering_tokens
    stub_request(:post, MESSAGES_URL).to_return(anthropic_body)
    result = Scribe::OcrStage.new(config: anthropic_config).call(documents, pages: 3)

    assert_equal 3, result.pages
    assert_equal 3, result.usage.pages
    assert_equal 900, result.usage.input_tokens
    assert_equal 120, result.usage.output_tokens
  end

  # No usage block from the provider still has to bill per page, so the count
  # survives and the event is flagged estimated.
  def test_pages_survive_a_missing_usage_block
    stub_request(:post, MESSAGES_URL).to_return(
      status: 200, headers: { "Content-Type" => "application/json" },
      body: { id: "m", type: "message", role: "assistant", stop_reason: "end_turn",
              content: [ { type: "text", text: "text" } ] }.to_json
    )
    result = Scribe::OcrStage.new(config: anthropic_config).call(documents, pages: 5)

    assert_equal 5, result.usage.pages
    assert result.usage.estimated
  end

  # ── request shape ────────────────────────────────────────────────────────

  def test_a_pdf_is_sent_as_a_base64_document_block
    stub_request(:post, MESSAGES_URL).to_return(anthropic_body)
    Scribe::OcrStage.new(config: anthropic_config).call(documents, pages: 1)

    assert_requested(:post, MESSAGES_URL) do |req|
      block = JSON.parse(req.body).dig("messages", 0, "content", 0)
      block["type"] == "document" &&
        block.dig("source", "media_type") == "application/pdf" &&
        block.dig("source", "data") == Base64.strict_encode64("%PDF-1.4 bytes")
    end
  end

  def test_an_image_is_sent_as_an_image_block
    stub_request(:post, MESSAGES_URL).to_return(anthropic_body)
    Scribe::OcrStage.new(config: anthropic_config).call(
      [ { data: "PNGDATA", content_type: "image/png", filename: "scan.png" } ], pages: 1
    )

    assert_requested(:post, MESSAGES_URL) do |req|
      JSON.parse(req.body).dig("messages", 0, "content", 0, "type") == "image"
    end
  end

  # Every uploaded file reaches the provider in one request, in the order given
  # — the orchestrator sorts by attachment id so that order is page order.
  def test_every_document_is_sent_in_order_in_one_request
    stub_request(:post, MESSAGES_URL).to_return(anthropic_body)
    Scribe::OcrStage.new(config: anthropic_config).call(
      [ { data: "one", content_type: "image/png", filename: "1.png" },
       { data: "two", content_type: "image/png", filename: "2.png" },
       { data: "three", content_type: "image/png", filename: "3.png" } ], pages: 3
    )

    assert_requested(:post, MESSAGES_URL, times: 1) do |req|
      blocks = JSON.parse(req.body).dig("messages", 0, "content")
      blocks.first(3).map { |b| Base64.decode64(b.dig("source", "data")) } == %w[one two three]
    end
  end
end
