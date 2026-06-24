FactoryBot.define do
  factory :model_price do
    provider { "openai" }
    model { "gpt-4o-mini" }
    input_per_million { 0.15 }
    output_per_million { 0.60 }
    currency { "USD" }
    effective_at { 1.day.ago }
    deprecated_at { nil }
  end
end
