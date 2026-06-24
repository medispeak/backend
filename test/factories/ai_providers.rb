FactoryBot.define do
  factory :ai_provider do
    sequence(:name) { |n| "Provider #{n}" }
    kind { "openai_compatible" }
    base_url { "https://api.openai.com/" }
    api_key { "sk-secret" }
    request_timeout { 120 }
  end
end
