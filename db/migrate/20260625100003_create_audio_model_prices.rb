class CreateAudioModelPrices < ActiveRecord::Migration[8.0]
  def change
    create_table :audio_model_prices do |t|
      t.string :provider
      t.string :model
      t.decimal :price_per_minute, precision: 16, scale: 8
      t.string :currency, default: "USD"
      t.datetime :effective_at
      t.datetime :deprecated_at

      t.timestamps
    end

    add_index :audio_model_prices, %i[provider model effective_at]
  end
end
