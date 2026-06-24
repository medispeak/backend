class CreateUsageEvents < ActiveRecord::Migration[8.0]
  def change
    create_table :usage_events do |t|
      t.bigint :account_id, null: false
      t.bigint :api_token_id
      t.bigint :scribe_session_id
      t.bigint :scribe_output_id
      t.string :function, null: false # asr | structuring | combined
      t.string :provider
      t.string :model
      t.string :model_version
      t.integer :input_tokens, null: false, default: 0
      t.integer :output_tokens, null: false, default: 0
      t.integer :total_tokens, null: false, default: 0
      t.decimal :audio_seconds, precision: 12, scale: 3, default: 0
      t.boolean :estimated, null: false, default: false
      t.decimal :unit_price_input, precision: 16, scale: 8
      t.decimal :unit_price_output, precision: 16, scale: 8
      t.decimal :unit_price_audio_min, precision: 16, scale: 8
      t.decimal :cost, precision: 12, scale: 6
      t.string :currency, default: "USD"
      t.decimal :fx_rate, precision: 16, scale: 8
      t.decimal :cost_settlement, precision: 12, scale: 6
      t.integer :latency_ms
      t.string :status, null: false, default: "pending"
      t.string :request_id
      t.datetime :reserved_until
      t.string :dedupe_key

      t.timestamps
    end

    add_index :usage_events, :account_id
    add_index :usage_events, :api_token_id
    add_index :usage_events, %i[account_id created_at]
    add_index :usage_events, %i[account_id model]
    add_index :usage_events, %i[api_token_id dedupe_key], unique: true,
              name: "index_usage_events_on_token_and_dedupe_key"
    add_index :usage_events, %i[status reserved_until]
  end
end
