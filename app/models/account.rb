class Account < ApplicationRecord
  has_many :users, dependent: :nullify
  has_many :api_tokens, dependent: :destroy
  has_one :account_credit, dependent: :destroy
  has_many :usage_events, dependent: :nullify

  validates :name, presence: true
  validates :status, presence: true

  before_create :ensure_webhook_secret

  private

  def ensure_webhook_secret
    self.webhook_secret ||= SecureRandom.hex(32)
  end
end
