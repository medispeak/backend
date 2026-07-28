# Adapter tests against stubbed HTTP (WebMock). No DB required.
# Standalone: `ruby -Itest test/services/llm/adapters/anthropic_adapter_test.rb`
require "minitest/autorun"
require "webmock/minitest"
require "faraday"

unless defined?(Rails)
  base = File.expand_path("../../../../app/services/llm", __dir__)
  %w[usage result error timeout rate_limited bad_response config adapter
     adapters/anthropic].each { |f| require_relative "#{base}/#{f}" }
end

class AnthropicAdapterTest < Minitest::Test
  ENDPOINT = "https://api.anthropic.com/v1/messages".freeze

  def setup
    WebMock.disable_net_connect!
  end

  def teardown
    WebMock.reset!
  end

  def config(base_url: "https://api.anthropic.com", model: "claude-3-5-sonnet-latest",
             caps: { can_transcribe: false }, options: {}, fallback: nil)
    Llm::Config.new(provider_kind: :anthropic, api_model_id: model,
                    base_url: base_url, api_key: "sk-ant-test",
                    capabilities: caps, options: options, fallback: fallback)
  end

  def adapter(cfg = config)
    Llm::Adapters::Anthropic.new(cfg)
  end

  def messages_body(input: { "name" => "Jane" }, stop: "tool_use", usage: { "input_tokens" => 31, "output_tokens" => 9 })
    {
      id: "msg_1",
      type: "message",
      role: "assistant",
      stop_reason: stop,
      content: [
        { type: "text", text: "Here is the extraction" },
        { type: "tool_use", id: "toolu_1", name: "extraction", input: input }
      ],
      usage: usage
    }.to_json
  end

  def core_schema
    { type: "object", additionalProperties: false,
      properties: { "name" => { type: "string", description: "Name" } },
      required: [ "name" ] }
  end

  def messages
    [ { role: "system", content: "You are an extractor." },
     { role: "user", content: "Patient is Jane." } ]
  end

  def test_structure_parses_tool_use_input
    stub_request(:post, ENDPOINT)
      .to_return(status: 200, headers: { "Content-Type" => "application/json" }, body: messages_body)

    result = adapter.structure(messages: messages, schema: core_schema)

    assert_equal({ "name" => "Jane" }, result.structured)
    assert_equal "tool_use", result.finish_reason
    assert_equal 31, result.usage.input_tokens
    assert_equal 9, result.usage.output_tokens
    assert_equal "anthropic", result.provider
    assert_equal "claude-3-5-sonnet-latest", result.model
    refute_nil result.raw
  end

  def test_structure_sends_anthropic_request_shape
    stub_request(:post, ENDPOINT)
      .to_return(status: 200, headers: { "Content-Type" => "application/json" }, body: messages_body)

    adapter.structure(messages: messages, schema: core_schema)

    assert_requested(:post, ENDPOINT) do |req|
      assert_equal "sk-ant-test", req.headers["X-Api-Key"]
      assert_equal "2023-06-01", req.headers["Anthropic-Version"]

      body = JSON.parse(req.body)
      body["model"] == "claude-3-5-sonnet-latest" &&
        body["max_tokens"] == 4096 &&
        body["system"] == "You are an extractor." &&
        # system message is hoisted out; only user/assistant turns remain
        body["messages"] == [ { "role" => "user", "content" => "Patient is Jane." } ] &&
        body.dig("tools", 0, "name") == "extraction" &&
        body.dig("tools", 0, "description") == "Extract structured data" &&
        # input_schema passed through as-is (real required subset, no nullable transform)
        body.dig("tools", 0, "input_schema", "required") == [ "name" ] &&
        body.dig("tools", 0, "input_schema", "properties", "name", "type") == "string" &&
        body["tool_choice"] == { "type" => "tool", "name" => "extraction" }
    end
  end

  def test_structure_honors_max_tokens_option
    stub_request(:post, ENDPOINT)
      .to_return(status: 200, headers: { "Content-Type" => "application/json" }, body: messages_body)

    adapter(config(options: { max_tokens: 1024 })).structure(messages: messages, schema: core_schema)

    assert_requested(:post, ENDPOINT) do |req|
      JSON.parse(req.body)["max_tokens"] == 1024
    end
  end

  def test_structure_without_system_message_omits_system
    stub_request(:post, ENDPOINT)
      .to_return(status: 200, headers: { "Content-Type" => "application/json" }, body: messages_body)

    only_user = [ { role: "user", content: "Patient is Jane." } ]
    adapter.structure(messages: only_user, schema: core_schema)

    assert_requested(:post, ENDPOINT) do |req|
      body = JSON.parse(req.body)
      body["system"].nil? &&
        body["messages"] == [ { "role" => "user", "content" => "Patient is Jane." } ]
    end
  end

  def test_missing_tool_use_block_maps_to_bad_response
    body = {
      stop_reason: "end_turn",
      content: [ { type: "text", text: "I cannot do that." } ],
      usage: { "input_tokens" => 5, "output_tokens" => 3 }
    }.to_json
    stub_request(:post, ENDPOINT)
      .to_return(status: 200, headers: { "Content-Type" => "application/json" }, body: body)

    assert_raises(Llm::BadResponse) do
      adapter.structure(messages: messages, schema: core_schema)
    end
  end

  def test_429_maps_to_rate_limited
    stub_request(:post, ENDPOINT)
      .to_return(status: 429, headers: { "Content-Type" => "application/json" },
                 body: { type: "error", error: { type: "rate_limit_error", message: "slow down" } }.to_json)

    assert_raises(Llm::RateLimited) do
      adapter.structure(messages: messages, schema: core_schema)
    end
  end

  def test_500_maps_to_bad_response
    stub_request(:post, ENDPOINT)
      .to_return(status: 500, headers: { "Content-Type" => "application/json" },
                 body: { type: "error", error: { type: "api_error", message: "boom" } }.to_json)

    assert_raises(Llm::BadResponse) do
      adapter.structure(messages: messages, schema: core_schema)
    end
  end

  def test_transcribe_raises_bad_response
    error = assert_raises(Llm::BadResponse) do
      adapter.transcribe(Object.new, language: "hi")
    end
    assert_match(/does not support audio transcription/, error.message)
  end
end
