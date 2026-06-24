class CreateIdempotencyKeys < ActiveRecord::Migration[8.0]
  def change
    create_table :idempotency_keys do |t|
      t.bigint :api_token_id, null: false
      t.string :key, null: false
      t.string :request_fingerprint
      t.jsonb :response_body
      t.integer :response_status
      t.datetime :expires_at

      t.timestamps
    end

    add_index :idempotency_keys, [ :api_token_id, :key ], unique: true,
              name: "index_idempotency_keys_on_token_and_key"
    add_index :idempotency_keys, :api_token_id
  end
end
