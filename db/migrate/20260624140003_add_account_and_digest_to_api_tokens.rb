require "digest"

class AddAccountAndDigestToApiTokens < ActiveRecord::Migration[8.0]
  def up
    add_column :api_tokens, :account_id, :bigint
    add_column :api_tokens, :token_digest, :string
    add_column :api_tokens, :token_prefix, :string
    add_column :api_tokens, :scopes, :string, array: true, default: []
    add_index :api_tokens, :token_digest, unique: true
    add_index :api_tokens, :account_id

    # Backfill account_id from the token's user, and digest/prefix from the
    # existing plaintext token so digest-based auth works for existing rows.
    select_all("SELECT t.id, t.token, u.account_id AS account_id FROM api_tokens t JOIN users u ON u.id = t.user_id").each do |row|
      digest = Digest::SHA256.hexdigest(row["token"].to_s)
      prefix = row["token"].to_s[0, 12]
      execute(<<~SQL)
        UPDATE api_tokens
        SET token_digest = #{quote(digest)},
            token_prefix = #{quote(prefix)},
            account_id = #{row['account_id'].to_i}
        WHERE id = #{row['id'].to_i}
      SQL
    end

    add_foreign_key :api_tokens, :accounts
  end

  def down
    remove_foreign_key :api_tokens, :accounts
    remove_index :api_tokens, :token_digest
    remove_index :api_tokens, :account_id
    remove_column :api_tokens, :account_id
    remove_column :api_tokens, :token_digest
    remove_column :api_tokens, :token_prefix
    remove_column :api_tokens, :scopes
  end
end
