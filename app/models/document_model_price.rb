# Optional per-page OCR price (mirrors AudioModelPrice). Vision providers bill
# tokens — that cost flows through ModelPrice with no row here — so a row in
# this table adds a per-page component (a Textract-style engine, or a per-page
# margin) purely as seed data.
class DocumentModelPrice < ApplicationRecord
  scope :current, ->(at = Time.current) {
    where("effective_at IS NULL OR effective_at <= ?", at)
      .where("deprecated_at IS NULL OR deprecated_at > ?", at)
      .order(effective_at: :desc)
  }

  validates :provider, presence: true
  validates :model, presence: true
end
