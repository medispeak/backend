require "test_helper"

class MeteringUsageRecorderTest < ActiveSupport::TestCase
  test "records a finalized event from an Llm::Result with correct cost and tokens" do
    account = create(:account)
    create(:model_price, provider: "openai", model: "gpt-4o-mini",
                         input_per_million: 0.15, output_per_million: 0.60)

    usage = Llm::Usage.new(input_tokens: 1_000_000, output_tokens: 500_000)
    result = Llm::Result.new(
      structured: { "ok" => true },
      model: "gpt-4o-mini",
      provider: "openai",
      usage: usage,
      latency_ms: 1234,
      finish_reason: "stop"
    )

    event = nil
    assert_difference("UsageEvent.count", 1) do
      event = Metering::UsageRecorder.record(account: account, function: :structuring, result: result)
    end

    assert_equal account.id, event.account_id
    assert_equal "structuring", event.function
    assert_equal "finalized", event.status
    assert_equal "openai", event.provider
    assert_equal "gpt-4o-mini", event.model
    assert_equal 1_000_000, event.input_tokens
    assert_equal 500_000, event.output_tokens
    assert_equal 1_500_000, event.total_tokens
    assert_equal 1234, event.latency_ms
    assert_in_delta 0.45, event.cost.to_f, 1e-9
    assert_equal 0.15, event.unit_price_input.to_f
    assert_equal 0.60, event.unit_price_output.to_f
    assert_not event.estimated
  end

  test "records audio seconds and audio unit price for asr" do
    account = create(:account)
    create(:audio_model_price, provider: "openai", model: "whisper-1", price_per_minute: 0.006)

    usage = Llm::Usage.new(audio_seconds: 120, estimated: true)
    result = Llm::Result.new(text: "hello", model: "whisper-1", provider: "openai",
                             usage: usage, latency_ms: 50)

    event = Metering::UsageRecorder.record(account: account, function: :asr, result: result)

    assert_equal "asr", event.function
    assert_in_delta 120.0, event.audio_seconds.to_f, 1e-9
    assert_equal 0.006, event.unit_price_audio_min.to_f
    assert_in_delta 0.012, event.cost.to_f, 1e-9
    assert event.estimated
  end

  test "handles a nil usage defensively" do
    account = create(:account)
    result = Llm::Result.new(text: "hi", model: "whisper-1", provider: "openai",
                             usage: nil, latency_ms: 10)

    event = nil
    assert_difference("UsageEvent.count", 1) do
      event = Metering::UsageRecorder.record(account: account, function: :asr, result: result)
    end

    assert_equal 0, event.input_tokens
    assert_equal 0, event.output_tokens
    assert_equal 0, event.total_tokens
    assert_in_delta 0.0, event.audio_seconds.to_f, 1e-9
    assert_equal 0, event.cost.to_f
    assert_not event.estimated
  end

  test "links api_token, scribe_session, and scribe_output and persists dedupe_key" do
    token = create(:api_token)
    account = token.account
    result = Llm::Result.new(structured: {}, model: "m", provider: "p", usage: nil)

    session = Struct.new(:id, :user_id).new(42, 7)
    output = Struct.new(:id).new(99)

    event = Metering::UsageRecorder.record(
      account: account,
      function: :structuring,
      result: result,
      api_token: token,
      scribe_session: session,
      scribe_output: output,
      dedupe_key: "abc-123"
    )

    assert_equal token.id, event.api_token_id
    assert_equal 42, event.scribe_session_id
    assert_equal 99, event.scribe_output_id
    assert_equal "abc-123", event.dedupe_key
    assert_equal 7, event.user_id, "the session's acting user is denormalized onto the event"
  end

  test "attributes user_id from the api_token owner when the session carries no user" do
    token = create(:api_token)
    result = Llm::Result.new(structured: {}, model: "m", provider: "p", usage: nil)

    event = Metering::UsageRecorder.record(
      account: token.account, function: :structuring, result: result, api_token: token
    )

    assert_equal token.user_id, event.user_id
  end

  test "can record a pending event" do
    account = create(:account)
    result = Llm::Result.new(structured: {}, model: "m", provider: "p", usage: nil)

    event = Metering::UsageRecorder.record(account: account, function: :structuring,
                                           result: result, status: :pending)

    assert_equal "pending", event.status
  end
end
