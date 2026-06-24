class AddAccountToUsers < ActiveRecord::Migration[8.0]
  def up
    add_reference :users, :account, null: true, index: true, foreign_key: true

    # Backfill: one account per existing user (greenfield-safe).
    select_all("SELECT id, email FROM users WHERE account_id IS NULL").each do |row|
      name = row["email"].to_s.empty? ? "Account #{row['id']}" : row["email"]
      execute(<<~SQL)
        INSERT INTO accounts (name, status, settings, created_at, updated_at)
        VALUES (#{quote(name)}, 'active', '{}', NOW(), NOW())
      SQL
      account_id = select_value("SELECT currval(pg_get_serial_sequence('accounts','id'))")
      execute("UPDATE users SET account_id = #{account_id.to_i} WHERE id = #{row['id'].to_i}")
    end
  end

  def down
    remove_reference :users, :account, foreign_key: true
  end
end
