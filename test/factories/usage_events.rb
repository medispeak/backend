FactoryBot.define do
  factory :usage_event do
    association :account
    function { "structuring" }
    status { "finalized" }
    provider { "openai" }
    model { "gpt-4o-mini" }
    input_tokens { 0 }
    output_tokens { 0 }
    total_tokens { 0 }
    audio_seconds { 0 }
    estimated { false }
    currency { "USD" }
  end
end
