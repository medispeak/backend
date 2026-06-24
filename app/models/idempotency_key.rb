class IdempotencyKey < ApplicationRecord
  belongs_to :api_token

  # An idempotency record is usable while it has no expiry or has not yet
  # expired. Replay/conflict checks only consult fresh records.
  scope :fresh, -> { where("expires_at IS NULL OR expires_at > ?", Time.current) }
end
