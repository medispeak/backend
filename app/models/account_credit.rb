class AccountCredit < ApplicationRecord
  belongs_to :account

  validates :account_id, uniqueness: true
  validates :balance, presence: true
end
