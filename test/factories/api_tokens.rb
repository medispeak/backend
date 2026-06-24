FactoryBot.define do
  factory :api_token do
    association :user
    sequence(:name) { |n| "Token #{n}" }
    expires_at { 1.day.from_now }
    # account + token/digest/prefix are set by ApiToken callbacks
  end
end
