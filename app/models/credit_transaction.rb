class CreditTransaction < ApplicationRecord
  belongs_to :account

  enum :txn_type, {
    hold: "hold",
    deduction: "deduction",
    refund: "refund",
    allocation: "allocation",
    adjustment: "adjustment"
  }

  validates :txn_type, presence: true
  validates :amount, presence: true
end
