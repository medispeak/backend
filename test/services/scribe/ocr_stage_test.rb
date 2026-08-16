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

# `defined?(Rails)` alone is not enough: `bin/rails test <this file>` defines the
# constant without booting the app, so nothing autoloads and Scribe/Llm are
# missing. Require the files ourselves unless the app is actually initialized.
unless defined?(Rails) && Rails.respond_to?(:application) && Rails.application&.initialized?
  llm = File.expand_path("../../../app/services/llm", __dir__)
  %w[usage result error timeout rate_limited bad_response refused config adapter
     adapters/anthropic adapters/openai_compatible registry caller].each { |f| require_relative "#{llm}/#{f}" }
  require_relative File.expand_path("../../../app/services/scribe/ocr_stage", __dir__)
end

class OcrStageTest < Minitest::Test
  MESSAGES_URL = "https://api.anthropic.com/v1/messages".freeze
  CHAT_URL = "https://api.openai.com/v1/chat/completions".freeze

  def setup; WebMock.disable_net_connect!; end
  def teardown; WebMock.reset!; end

  def anthropic_config(fallback: nil, capabilities: {})
    Llm::Config.new(provider_kind: :anthropic, api_model_id: "claude-3-5-sonnet-latest",
                    base_url: "https://api.anthropic.com", api_key: "sk-ant-test",
                    capabilities: capabilities, fallback: fallback)
  end

  def openai_config(capabilities: {}, options: {})
    Llm::Config.new(provider_kind: :openai_compatible, api_model_id: "gpt-4o-mini",
                    base_url: "https://api.openai.com/", api_key: "sk-test",
                    capabilities: capabilities, options: options)
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

  # A refusal is a decision, not a truncation: the client must not be told the
  # document was too long, and the fallback provider is not spent on it (Refused
  # is outside Caller::TRANSIENT). It is still a billed round-trip.
  def test_a_refusal_raises_refused_and_is_not_retried_on_the_fallback
    stub_request(:post, MESSAGES_URL).to_return(anthropic_body(text: "I can't help with that.", stop: "refusal"))
    stub_request(:post, CHAT_URL).to_return(openai_body(text: "Full report text"))

    error = assert_raises(Llm::Refused) do
      Scribe::OcrStage.new(config: anthropic_config(fallback: openai_config)).call(documents, pages: 2)
    end
    assert_match(/refused/, error.message)
    assert_equal false, error.message.include?("too long"), "a refusal must not be diagnosed as truncation"
    assert error.billable?
    assert_not_requested :post, CHAT_URL
  end

  def test_openai_content_filter_is_a_refusal_too
    stub_request(:post, CHAT_URL).to_return(openai_body(finish: "content_filter"))

    assert_raises(Llm::Refused) do
      Scribe::OcrStage.new(config: openai_config).call(documents, pages: 2)
    end
  end

  def test_finish_reason_is_carried_on_the_result
    stub_request(:post, MESSAGES_URL).to_return(anthropic_body(stop: "end_turn"))
    result = Scribe::OcrStage.new(config: anthropic_config).call(documents, pages: 1)
    assert_equal "end_turn", result.finish_reason
  end

  # ── output budget ────────────────────────────────────────────────────────

  def test_max_tokens_scales_with_page_count_not_the_structuring_default
    stub_request(:post, MESSAGES_URL).to_return(anthropic_body)
    Scribe::OcrStage.new(config: anthropic_config).call(documents, pages: 3)

    assert_requested(:post, MESSAGES_URL) do |req|
      JSON.parse(req.body)["max_tokens"] == 3 * Scribe::OcrStage::TOKENS_PER_PAGE
    end
  end

  def test_max_tokens_has_a_floor_for_single_page_and_image_uploads
    stub_request(:post, MESSAGES_URL).to_return(anthropic_body)
    Scribe::OcrStage.new(config: anthropic_config).call(documents, pages: 1)

    assert_requested(:post, MESSAGES_URL) do |req|
      JSON.parse(req.body)["max_tokens"] == Scribe::OcrStage::MIN_MAX_TOKENS
    end
  end

  # A spoofed page count must not turn into an absurd completion request. The
  # model here declares a huge ceiling so it is the STAGE cap being exercised,
  # not the adapter's.
  def test_max_tokens_is_capped
    stub_request(:post, MESSAGES_URL).to_return(anthropic_body)
    Scribe::OcrStage.new(config: anthropic_config(capabilities: { max_output_tokens: 1_000_000 }))
                    .call(documents, pages: 100_000)

    assert_requested(:post, MESSAGES_URL) do |req|
      JSON.parse(req.body)["max_tokens"] == Scribe::OcrStage::MAX_MAX_TOKENS
    end
  end

  # ── output ceiling ───────────────────────────────────────────────────────
  #
  # Providers 400 a request whose budget exceeds the model's output ceiling,
  # before doing any work. A budget sized only from the page count would fail
  # every long document outright on the default models (gpt-4o-mini: 16k,
  # claude-3-5-*: 8k), so each adapter clamps to what ITS model accepts.

  def test_anthropic_clamps_the_budget_to_its_default_output_ceiling
    stub_request(:post, MESSAGES_URL).to_return(anthropic_body)
    Scribe::OcrStage.new(config: anthropic_config).call(documents, pages: 12)

    assert_requested(:post, MESSAGES_URL) do |req|
      JSON.parse(req.body)["max_tokens"] == Llm::Adapters::Anthropic::DEFAULT_OUTPUT_CEILING
    end
  end

  def test_openai_clamps_the_budget_to_its_default_output_ceiling
    stub_request(:post, CHAT_URL).to_return(openai_body)
    Scribe::OcrStage.new(config: openai_config).call(documents, pages: 12)

    assert_requested(:post, CHAT_URL) do |req|
      JSON.parse(req.body)["max_completion_tokens"] == Llm::Adapters::OpenaiCompatible::DEFAULT_OUTPUT_CEILING
    end
  end

  # A model that allows more says so in capabilities, and the page-sized budget
  # then goes through unclamped.
  def test_a_declared_max_output_tokens_capability_raises_the_ceiling
    stub_request(:post, MESSAGES_URL).to_return(anthropic_body)
    Scribe::OcrStage.new(config: anthropic_config(capabilities: { max_output_tokens: 64_000 }))
                    .call(documents, pages: 12)

    assert_requested(:post, MESSAGES_URL) do |req|
      JSON.parse(req.body)["max_tokens"] == 12 * Scribe::OcrStage::TOKENS_PER_PAGE
    end
  end

  # The assignment's options can also carry it, for a model row nobody has
  # annotated yet.
  def test_an_assignment_option_can_declare_the_ceiling_too
    stub_request(:post, CHAT_URL).to_return(openai_body)
    Scribe::OcrStage.new(config: openai_config(options: { max_output_tokens: 32_768 }))
                    .call(documents, pages: 12)

    assert_requested(:post, CHAT_URL) do |req|
      JSON.parse(req.body)["max_completion_tokens"] == 12 * Scribe::OcrStage::TOKENS_PER_PAGE
    end
  end

  # Primary and fallback are different models with different ceilings; the
  # SAME requested budget must be clamped for each, or the fallback 400s on a
  # number that suited the primary.
  def test_the_fallback_attempt_is_clamped_to_its_own_ceiling
    stub_request(:post, CHAT_URL).to_return(openai_body(finish: "length"))
    stub_request(:post, MESSAGES_URL).to_return(anthropic_body(text: "Full report text"))

    openai_primary = Llm::Config.new(provider_kind: :openai_compatible, api_model_id: "gpt-4o-mini",
                                     base_url: "https://api.openai.com/", api_key: "sk-test",
                                     fallback: anthropic_config)
    result = Scribe::OcrStage.new(config: openai_primary).call(documents, pages: 12)

    assert_equal "Full report text", result.text
    assert_requested(:post, CHAT_URL) do |req|
      JSON.parse(req.body)["max_completion_tokens"] == 16_384
    end
    assert_requested(:post, MESSAGES_URL) do |req|
      JSON.parse(req.body)["max_tokens"] == 8_192
    end
  end

  # OpenAI proper: `max_tokens` is deprecated there and rejected by the o-series
  # and GPT-5, while `max_completion_tokens` is accepted by every current model.
  def test_openai_ocr_sends_the_budget_as_max_completion_tokens
    stub_request(:post, CHAT_URL).to_return(openai_body)
    Scribe::OcrStage.new(config: openai_config).call(documents, pages: 6)

    assert_requested(:post, CHAT_URL) do |req|
      body = JSON.parse(req.body)
      body["max_completion_tokens"] == 6 * Scribe::OcrStage::TOKENS_PER_PAGE && !body.key?("max_tokens")
    end
  end

  # Any other OpenAI-compatible endpoint (Ollama, vLLM, OpenRouter, ...) gets the
  # universally understood `max_tokens`; some of them reject the newer name.
  def test_other_openai_compatible_hosts_get_max_tokens
    compat_url = "https://llm.internal.example/v1/chat/completions"
    config = Llm::Config.new(provider_kind: :openai_compatible, api_model_id: "qwen2.5-vl",
                             base_url: "https://llm.internal.example/", api_key: "k")
    stub_request(:post, compat_url).to_return(openai_body)
    Scribe::OcrStage.new(config: config).call(documents, pages: 6)

    assert_requested(:post, compat_url) do |req|
      body = JSON.parse(req.body)
      body["max_tokens"] == 6 * Scribe::OcrStage::TOKENS_PER_PAGE && !body.key?("max_completion_tokens")
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
