FactoryBot.define do
  factory :model_assignment do
    association :ai_model
    scope_type { "System" }
    scope_id { nil }
    function { "structuring" }
  end
end
