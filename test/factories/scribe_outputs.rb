FactoryBot.define do
  factory :scribe_output do
    association :scribe_session
    output_type { "form" }
    status { "pending" }
  end
end
