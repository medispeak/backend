# OCR modality (lab reports): a scribe session is either "audio" (ASR) or
# "document" (vision OCR). Documents are metered in pages alongside tokens;
# document_model_prices mirrors audio_model_prices so per-page billing is a
# seed-data decision, not a code change.
class AddDocumentModality < ActiveRecord::Migration[8.0]
  def change
    add_column :scribe_sessions, :modality, :string, null: false, default: "audio"
    add_column :scribe_sessions, :document_pages, :integer, null: false, default: 0

    add_column :usage_events, :pages, :integer, null: false, default: 0
    add_column :usage_events, :unit_price_page, :decimal, precision: 16, scale: 8

    create_table :document_model_prices do |t|
      t.string :provider
      t.string :model
      t.decimal :price_per_page, precision: 16, scale: 8
      t.string :currency, default: "USD"
      t.datetime :effective_at
      t.datetime :deprecated_at
      t.timestamps
      t.index [ :provider, :model, :effective_at ]
    end
  end
end
