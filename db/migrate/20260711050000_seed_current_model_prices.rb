# Ensures the provider-cost price rows exist for the models actually in use, so
# usage/cost is non-zero once the provider-name fix lands (the ledger recorded
# the provider *kind* before, which never matched the name-keyed price rows).
# Idempotent: only creates missing rows, never overwrites an operator's prices.
class SeedCurrentModelPrices < ActiveRecord::Migration[8.0]
  TOKEN_PRICES = [
    { provider: "OpenAI", model: "gpt-4.1-mini", input: 0.40, output: 1.60 },
    { provider: "OpenAI", model: "gpt-4o-mini", input: 0.15, output: 0.60 },
    { provider: "OpenAI", model: "gpt-4o-transcribe", input: 2.50, output: 10.00 }
  ].freeze

  AUDIO_PRICES = [
    { provider: "OpenAI", model: "whisper-1", per_min: 0.006 },
    { provider: "OpenAI", model: "gpt-4o-transcribe", per_min: 0.006 }
  ].freeze

  def up
    now = Time.current
    TOKEN_PRICES.each do |p|
      row = ModelPrice.find_or_initialize_by(provider: p[:provider], model: p[:model])
      next unless row.new_record?

      row.update!(input_per_million: p[:input], output_per_million: p[:output],
                  currency: "USD", effective_at: now)
    end
    AUDIO_PRICES.each do |a|
      row = AudioModelPrice.find_or_initialize_by(provider: a[:provider], model: a[:model])
      next unless row.new_record?

      row.update!(price_per_minute: a[:per_min], currency: "USD", effective_at: now)
    end
  end

  def down
    # Prices are configuration; leave them in place.
  end
end
