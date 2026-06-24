FactoryBot.define do
  factory :account_credit do
    association :account
    balance { 100 }
    credit_limit { nil }
    refill_period { nil }
  end
end
