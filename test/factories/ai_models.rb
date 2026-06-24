FactoryBot.define do
  factory :ai_model do
    association :ai_provider
    sequence(:api_model_id) { |n| "model-#{n}" }
    capabilities { { "supports_json_schema" => true } }
  end
end
