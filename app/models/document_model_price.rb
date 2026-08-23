# Optional per-page OCR price (mirrors AudioModelPrice). Vision providers bill
# tokens — that cost flows through ModelPrice with no row here — so a row in
# this table adds a per-page component (a Textract-style engine, or a per-page
# margin) purely as seed data.
class DocumentModelPrice < ApplicationRecord
  include EffectiveDated

  validates :provider, presence: true
  validates :model, presence: true
end
