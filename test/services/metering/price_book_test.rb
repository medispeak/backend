require "test_helper"

class MeteringPriceBookTest < ActiveSupport::TestCase
  test "computes token cost for structuring" do
    create(:model_price, provider: "openai", model: "gpt-4o-mini",
                         input_per_million: 0.15, output_per_million: 0.60)
    usage = Llm::Usage.new(input_tokens: 1_000_000, output_tokens: 500_000)

    result = Metering::PriceBook.cost(function: :structuring, provider: "openai",
                                      model: "gpt-4o-mini", usage: usage)

    # 1M * 0.15 + 0.5M * 0.60 = 0.15 + 0.30 = 0.45
    assert_in_delta 0.45, result[:cost], 1e-9
    assert_equal 0.15, result[:unit_price_input].to_f
    assert_equal 0.60, result[:unit_price_output].to_f
    assert_nil result[:unit_price_audio_min]
    assert_equal "USD", result[:currency]
  end

  test "computes per-minute audio cost for asr" do
    create(:audio_model_price, provider: "openai", model: "whisper-1",
                               price_per_minute: 0.006)
    usage = Llm::Usage.new(audio_seconds: 120) # 2 minutes

    result = Metering::PriceBook.cost(function: :asr, provider: "openai",
                                      model: "whisper-1", usage: usage)

    # 120/60 * 0.006 = 2 * 0.006 = 0.012
    assert_in_delta 0.012, result[:cost], 1e-9
    assert_equal 0.006, result[:unit_price_audio_min].to_f
    assert_nil result[:unit_price_input]
  end

  test "does not round audio minutes (fractional minutes bill proportionally)" do
    create(:audio_model_price, provider: "openai", model: "whisper-1",
                               price_per_minute: 0.006)
    usage = Llm::Usage.new(audio_seconds: 90) # 1.5 minutes

    result = Metering::PriceBook.cost(function: :asr, provider: "openai",
                                      model: "whisper-1", usage: usage)

    # 90/60 * 0.006 = 1.5 * 0.006 = 0.009
    assert_in_delta 0.009, result[:cost], 1e-9
  end

  test "combined sums audio and token portions" do
    create(:model_price, provider: "openai", model: "gpt-4o-audio",
                         input_per_million: 0.15, output_per_million: 0.60)
    create(:audio_model_price, provider: "openai", model: "gpt-4o-audio",
                               price_per_minute: 0.006)
    usage = Llm::Usage.new(input_tokens: 1_000_000, output_tokens: 0, audio_seconds: 60)

    result = Metering::PriceBook.cost(function: :combined, provider: "openai",
                                      model: "gpt-4o-audio", usage: usage)

    # tokens: 1M * 0.15 = 0.15 ; audio: 1 min * 0.006 = 0.006 ; total 0.156
    assert_in_delta 0.156, result[:cost], 1e-9
    assert_equal 0.15, result[:unit_price_input].to_f
    assert_equal 0.006, result[:unit_price_audio_min].to_f
  end

  test "returns zero cost when no price row exists" do
    usage = Llm::Usage.new(input_tokens: 1_000_000, output_tokens: 1_000_000)

    result = Metering::PriceBook.cost(function: :structuring, provider: "nope",
                                      model: "no-model", usage: usage)

    assert_equal 0, result[:cost]
    assert_nil result[:unit_price_input]
    assert_nil result[:unit_price_output]
  end

  test "ignores deprecated price rows" do
    create(:model_price, provider: "openai", model: "gpt-4o-mini",
                         input_per_million: 0.15, output_per_million: 0.60,
                         effective_at: 10.days.ago, deprecated_at: 1.day.ago)
    usage = Llm::Usage.new(input_tokens: 1_000_000)

    result = Metering::PriceBook.cost(function: :structuring, provider: "openai",
                                      model: "gpt-4o-mini", usage: usage)

    assert_equal 0, result[:cost]
  end

  test "rounds cost to six decimal places" do
    create(:audio_model_price, provider: "openai", model: "whisper-1",
                               price_per_minute: 0.00012345678)
    usage = Llm::Usage.new(audio_seconds: 7)

    result = Metering::PriceBook.cost(function: :asr, provider: "openai",
                                      model: "whisper-1", usage: usage)

    assert_equal result[:cost], result[:cost].round(6)
  end
end
