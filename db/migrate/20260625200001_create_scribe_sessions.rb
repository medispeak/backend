class CreateScribeSessions < ActiveRecord::Migration[8.0]
  def change
    create_table :scribe_sessions do |t|
      t.bigint :account_id, null: false
      t.bigint :api_token_id
      t.bigint :user_id
      t.string :status, null: false, default: "created"
      t.string :language
      t.string :mode, default: "consultation"
      t.string :idempotency_key
      t.string :callback_url
      t.datetime :expires_at
      t.jsonb :error, null: false, default: {}

      t.timestamps
    end

    add_index :scribe_sessions, :account_id
    add_index :scribe_sessions, :api_token_id
    add_index :scribe_sessions, :user_id
    # Unique per token. Multiple NULLs are allowed in PostgreSQL, so sessions
    # without an idempotency_key (or without an api_token) don't collide.
    add_index :scribe_sessions, %i[api_token_id idempotency_key], unique: true,
              name: "index_scribe_sessions_on_token_and_idempotency_key"

    add_foreign_key :scribe_sessions, :accounts
  end
end
