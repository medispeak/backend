class Account < ApplicationRecord
  has_many :users, dependent: :nullify
  has_many :api_tokens, dependent: :destroy
  has_one :account_credit, dependent: :destroy
  has_many :usage_events, dependent: :nullify

  validates :name, presence: true
  validates :status, presence: true

  before_create :ensure_webhook_secret

  # Scalar summaries for the admin dashboard (avoids linking to dashboard-less
  # AccountCredit / ApiToken resources).
  def credit_balance
    account_credit&.balance&.to_s || "—"
  end

  def api_tokens_count
    api_tokens.count
  end

  private

  def ensure_webhook_secret
    self.webhook_secret ||= SecureRandom.hex(32)
  end
end
