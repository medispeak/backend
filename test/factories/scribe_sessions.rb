FactoryBot.define do
  factory :scribe_session do
    association :account
    status { "created" }
    mode { "consultation" }
    expires_at { 1.day.from_now }
  end
end
