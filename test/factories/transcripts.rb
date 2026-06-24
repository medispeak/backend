FactoryBot.define do
  factory :transcript do
    association :scribe_session
    text { "Patient reports a mild headache." }
    language { "en" }
    duration_seconds { 12.345 }
    provider { "openai" }
    model { "whisper-1" }
  end
end
