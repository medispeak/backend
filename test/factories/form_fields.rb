FactoryBot.define do
  factory :form_field do
    association :page
    sequence(:title) { |n| "Field #{n}" }
    sequence(:friendly_name) { |n| "field_#{n}" }
    field_type { "string" }
    description { "A clinical field" }
  end
end
