FactoryBot.define do
  factory :template do
    sequence(:name) { |n| "Template #{n}" }
    description { "A medical form template" }
  end
end
