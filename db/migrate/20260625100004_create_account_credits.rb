class CreateAccountCredits < ActiveRecord::Migration[8.0]
  def change
    create_table :account_credits do |t|
      t.bigint :account_id, null: false
      t.decimal :balance, precision: 16, scale: 6, null: false, default: 0
      t.decimal :credit_limit, precision: 16, scale: 6
      t.string :refill_period

      t.timestamps
    end

    add_index :account_credits, :account_id, unique: true
    add_foreign_key :account_credits, :accounts
  end
end
