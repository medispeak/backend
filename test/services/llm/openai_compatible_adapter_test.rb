# Adapter + Caller tests against stubbed HTTP (WebMock). No DB required.
# Standalone: `ruby -Itest test/services/llm/openai_compatible_adapter_test.rb`
require "minitest/autorun"
require "webmock/minitest"
require "tempfile"
require "openai"

unless defined?(Rails)
  base = File.expand_path("../../../app/services/llm", __dir__)
  %w[usage result error timeout rate_limited bad_response config adapter
     adapters/openai_compatible registry caller].each { |f| require_relative "#{base}/#{f}" }
end

class OpenaiCompatibleAdapterTest < Minitest::Test
  def setup
    WebMock.disable_net_connect!
  end

  def teardown
    WebMock.reset!
  end

  def config(base_url: "https://api.openai.com/", model: "gpt-4o-mini", caps: { supports_json_schema: true }, fallback: nil)
    Llm::Config.new(provider_kind: :openai_compatible, api_model_id: model,
                    base_url: base_url, api_key: "sk-test", capabilities: caps, fallback: fallback)
  end

  def adapter(cfg = config)
    Llm::Adapters::OpenaiCompatible.new(cfg)
  end

  def chat_body(content: { "name" => "Jane" }, finish: "stop")
    { choices: [{ message: { content: content.to_json }, finish_reason: finish }],
      usage: { prompt_tokens: 12, completion_tokens: 4 } }.to_json
  end

  def core_schema
    { type: "object", additionalProperties: false,
      properties: { "name" => { type: "string", description: "Name" } }, required: [] }
  end

  def test_transcribe_returns_normalized_result
    stub_request(:post, "https://api.openai.com/v1/audio/transcriptions")
      .to_return(status: 200, headers: { "Content-Type" => "application/json" },
                 body: { text: "namaste doctor" }.to_json)

    file = Tempfile.new(["clip", ".mp3"]); file.write("x"); file.rewind
    result = adapter.transcribe(file, language: "hi", mode: :transcribe, audio_seconds: 30)

    assert_equal "namaste doctor", result.text
    assert_equal 30.0, result.usage.audio_seconds
    assert_equal "openai_compatible", result.provider
    assert_equal "gpt-4o-mini", result.model
  ensure
    file&.close!
  end

  def test_structure_sends_strict_json_schema_and_parses_result
    stub_request(:post, "https://api.openai.com/v1/chat/completions")
      .to_return(status: 200, headers: { "Content-Type" => "application/json" }, body: chat_body)

    result = adapter.structure(messages: [{ role: "user", content: "hi" }], schema: core_schema)

    assert_equal({ "name" => "Jane" }, result.structured)
    assert_equal "stop", result.finish_reason
    assert_equal 12, result.usage.input_tokens
    assert_equal 4, result.usage.output_tokens

    assert_requested(:post, "https://api.openai.com/v1/chat/completions") do |req|
      body = JSON.parse(req.body)
      rf = body["response_format"]
      rf && rf["type"] == "json_schema" &&
        rf.dig("json_schema", "strict") == true &&
        rf.dig("json_schema", "schema", "required") == ["name"] &&
        rf.dig("json_schema", "schema", "properties", "name", "type") == ["string", "null"]
    end
  end

  def test_429_maps_to_rate_limited
    stub_request(:post, "https://api.openai.com/v1/chat/completions")
      .to_return(status: 429, headers: { "Content-Type" => "application/json" },
                 body: { error: { message: "slow down" } }.to_json)

    assert_raises(Llm::RateLimited) do
      adapter.structure(messages: [{ role: "user", content: "hi" }], schema: core_schema)
    end
  end

  def test_500_maps_to_bad_response
    stub_request(:post, "https://api.openai.com/v1/chat/completions")
      .to_return(status: 500, headers: { "Content-Type" => "application/json" },
                 body: { error: { message: "boom" } }.to_json)

    assert_raises(Llm::BadResponse) do
      adapter.structure(messages: [{ role: "user", content: "hi" }], schema: core_schema)
    end
  end

  def test_caller_falls_back_on_rate_limit
    stub_request(:post, "https://primary.test/v1/chat/completions")
      .to_return(status: 429, body: { error: {} }.to_json, headers: { "Content-Type" => "application/json" })
    stub_request(:post, "https://fallback.test/v1/chat/completions")
      .to_return(status: 200, body: chat_body(content: { "name" => "Fallback" }), headers: { "Content-Type" => "application/json" })

    fb = config(base_url: "https://fallback.test/")
    primary = config(base_url: "https://primary.test/", fallback: fb)

    result = Llm::Caller.structure(primary, messages: [{ role: "user", content: "hi" }], schema: core_schema)
    assert_equal({ "name" => "Fallback" }, result.structured)
    assert_requested(:post, "https://fallback.test/v1/chat/completions", times: 1)
  end

  def test_caller_reraises_without_fallback
    stub_request(:post, "https://api.openai.com/v1/chat/completions")
      .to_return(status: 429, body: { error: {} }.to_json, headers: { "Content-Type" => "application/json" })

    assert_raises(Llm::RateLimited) do
      Llm::Caller.structure(config, messages: [{ role: "user", content: "hi" }], schema: core_schema)
    end
  end
end
