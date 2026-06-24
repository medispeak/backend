FactoryBot.define do
  factory :audio_model_price do
    provider { "openai" }
    model { "whisper-1" }
    price_per_minute { 0.006 }
    currency { "USD" }
    effective_at { 1.day.ago }
    deprecated_at { nil }
  end
end
