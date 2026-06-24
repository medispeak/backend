class CreateModelPrices < ActiveRecord::Migration[8.0]
  def change
    create_table :model_prices do |t|
      t.string :provider
      t.string :model
      t.decimal :input_per_million, precision: 16, scale: 8
      t.decimal :output_per_million, precision: 16, scale: 8
      t.string :currency, default: "USD"
      t.datetime :effective_at
      t.datetime :deprecated_at

      t.timestamps
    end

    add_index :model_prices, %i[provider model effective_at]
  end
end
