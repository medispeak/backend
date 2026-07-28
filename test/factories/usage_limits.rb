FactoryBot.define do
  factory :usage_limit do
    association :account
    scope { "subtree" }
    metric { "cost" }
    period { "monthly" }
    limit_value { 100 }
  end
end
