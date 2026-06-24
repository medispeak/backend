FactoryBot.define do
  factory :page do
    association :template
    sequence(:name) { |n| "Page #{n}" }
  end
end
