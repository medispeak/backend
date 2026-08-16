# Stage orchestration tests against stubbed HTTP (WebMock). No DB.
# Standalone: `ruby -Itest test/services/scribe/stages_test.rb`
require "minitest/autorun"
require "webmock/minitest"
require "tempfile"
require "openai"
require "json_schemer"

unless defined?(Rails)
  llm = File.expand_path("../../../app/services/llm", __dir__)
  %w[usage result error timeout rate_limited bad_response config adapter
     adapters/openai_compatible registry caller].each { |f| require_relative "#{llm}/#{f}" }
  scribe = File.expand_path("../../../app/services/scribe", __dir__)
  %w[schema_builder schema_validator structuring_stage asr_stage].each { |f| require_relative "#{scribe}/#{f}" }
end

# Duck-typed FormField stand-in (no ActiveRecord).
StageField = Struct.new(:title, :friendly_name, :description, :field_type,
                        :enum_options, :minimum, :maximum, keyword_init: true)

class StructuringStageTest < Minitest::Test
  CHAT_URL = "https://api.openai.com/v1/chat/completions".freeze

  def setup; WebMock.disable_net_connect!; end
  def teardown; WebMock.reset!; end

  def config
    Llm::Config.new(provider_kind: :openai_compatible, api_model_id: "gpt-4o-mini",
                    base_url: "https://api.openai.com/", api_key: "sk-test",
                    capabilities: { supports_json_schema: true })
  end

  def fields
    [ StageField.new(title: "age", friendly_name: "Age", field_type: "number", minimum: "0", maximum: "120"),
     StageField.new(title: "name", friendly_name: "Name", field_type: "string") ]
  end

  def chat_stub(content, finish: "stop")
    { status: 200, headers: { "Content-Type" => "application/json" },
      body: { choices: [ { message: { content: content.to_json }, finish_reason: finish } ],
              usage: { prompt_tokens: 5, completion_tokens: 2 } }.to_json }
  end

  def stage
    Scribe::StructuringStage.new(config: config, fields: fields, system_prompt: "Fill the form.")
  end

  def test_happy_path_returns_valid_structured
    stub_request(:post, CHAT_URL).to_return(chat_stub({ "age" => 30, "name" => "Jane" }))
    result = stage.call("patient is 30 named jane")
    assert result.valid
    assert_equal({ "age" => 30, "name" => "Jane" }, result.structured)
    assert_empty result.errors
    assert_equal 5, result.usage.input_tokens
  end

  def test_repairs_constraint_violation_once
    stub_request(:post, CHAT_URL).to_return(
      chat_stub({ "age" => 200, "name" => "Jane" }), # invalid: > max
      chat_stub({ "age" => 100, "name" => "Jane" })  # repaired
    )
    result = stage.call("...")
    assert result.valid, "should be valid after one repair: #{result.errors.inspect}"
    assert_equal 100, result.structured["age"]
    assert_requested :post, CHAT_URL, times: 2
  end

  def test_returns_invalid_when_repair_still_fails
    stub_request(:post, CHAT_URL).to_return(
      chat_stub({ "age" => 200 }), chat_stub({ "age" => 300 })
    )
    result = stage.call("...")
    refute result.valid
    refute_empty result.errors
    assert_requested :post, CHAT_URL, times: 2 # exactly one repair, not a loop
  end

  def test_finish_reason_length_raises
    stub_request(:post, CHAT_URL).to_return(chat_stub({ "age" => 30 }, finish: "length"))
    assert_raises(Llm::BadResponse) { stage.call("...") }
  end
end

class AsrStageTest < Minitest::Test
  def setup; WebMock.disable_net_connect!; end
  def teardown; WebMock.reset!; end

  def config
    Llm::Config.new(provider_kind: :openai_compatible, api_model_id: "whisper-1",
                    base_url: "https://api.openai.com/", api_key: "sk-test",
                    capabilities: { can_transcribe: true })
  end

  def test_transcribe_returns_normalized_transcript
    stub_request(:post, "https://api.openai.com/v1/audio/transcriptions")
      .to_return(status: 200, headers: { "Content-Type" => "application/json" },
                 body: { text: "hello world" }.to_json)
    file = Tempfile.new([ "a", ".mp3" ]); file.write("x"); file.rewind

    res = Scribe::AsrStage.new(config: config).call(file, language: "en", mode: :transcribe, audio_seconds: 12)

    assert_equal "hello world", res.text
    assert_equal 12, res.duration_seconds
    assert_equal "whisper-1", res.model
    assert_equal "en", res.language
  ensure
    file&.close!
  end

  # The API advertises language_hint "auto" (GET /api/v2/config, docs/api/v2.md).
  # It is a portable "no hint", NOT a language code: passed through, Sarvam
  # built "auto-IN" and 400'd every segment (prod session 62, 2026-08-16), and
  # Whisper would reject it too. The stage must drop it before any adapter.
  def test_language_auto_is_sent_as_no_language_hint
    stub_request(:post, "https://api.openai.com/v1/audio/transcriptions")
      .to_return(status: 200, headers: { "Content-Type" => "application/json" },
                 body: { text: "hello" }.to_json)
    file = Tempfile.new([ "a", ".mp3" ]); file.write("x"); file.rewind

    res = Scribe::AsrStage.new(config: config).call(file, language: "auto", mode: :transcribe, audio_seconds: 3)

    assert_requested(:post, "https://api.openai.com/v1/audio/transcriptions") do |req|
      !req.body.include?('name="language"')
    end
    assert_nil res.language, "no provider-detected language and no real hint -> nil, never 'auto'"
  ensure
    file&.close!
  end
end
