require "digest"

class ApiToken < ApplicationRecord
  TOKEN_PREFIX = "msk_live_".freeze

  belongs_to :user
  belongs_to :account

  # The plaintext token is available only on the instance that created it
  # (reveal-once). Persisted state is the digest.
  attr_reader :raw_token

  validates :token, presence: true, uniqueness: true
  validates :token_digest, presence: true, uniqueness: true
  validates :expires_at, presence: true
  validates :name, presence: true

  before_validation :set_account_from_user
  before_validation :generate_token, on: :create

  scope :active, -> { where(active: true).where("expires_at > ?", Time.current) }

  # Resolve an active token from a raw bearer string (constant-work digest
  # lookup). Returns nil for blank/unknown/expired/inactive tokens.
  def self.authenticate(raw)
    return nil if raw.to_s.strip.empty?

    active.find_by(token_digest: digest_for(raw))
  end

  def self.digest_for(raw)
    Digest::SHA256.hexdigest(raw.to_s)
  end

  private

  def set_account_from_user
    self.account ||= user&.account
  end

  def generate_token
    return if token_digest.present?

    raw = "#{TOKEN_PREFIX}#{SecureRandom.hex(20)}"
    @raw_token = raw
    # Transitional dual-write: the legacy `token` column is NOT NULL until the
    # plaintext column is dropped. Auth uses token_digest only.
    self.token = raw
    self.token_digest = self.class.digest_for(raw)
    self.token_prefix = raw[0, 12]
  end
end
