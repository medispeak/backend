FactoryBot.define do
  factory :credit_transaction do
    association :account
    txn_type { "hold" }
    amount { 1 }
  end
end
