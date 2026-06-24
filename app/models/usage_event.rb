class UsageEvent < ApplicationRecord
  belongs_to :account
  belongs_to :api_token, optional: true

  enum :function, { asr: "asr", structuring: "structuring", combined: "combined" }
  enum :status, { pending: "pending", finalized: "finalized", failed: "failed" }

  validates :function, presence: true
  validates :status, presence: true
end
