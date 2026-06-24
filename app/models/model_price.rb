class ModelPrice < ApplicationRecord
  scope :current, ->(at = Time.current) {
    where("effective_at IS NULL OR effective_at <= ?", at)
      .where("deprecated_at IS NULL OR deprecated_at > ?", at)
      .order(effective_at: :desc)
  }

  validates :provider, presence: true
  validates :model, presence: true
end
