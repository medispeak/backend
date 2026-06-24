class CreateCreditTransactions < ActiveRecord::Migration[8.0]
  def change
    create_table :credit_transactions do |t|
      t.bigint :account_id, null: false
      t.string :txn_type, null: false # hold | deduction | refund | allocation | adjustment
      t.decimal :amount, precision: 16, scale: 6, null: false
      t.decimal :balance_before, precision: 16, scale: 6
      t.decimal :balance_after, precision: 16, scale: 6
      t.bigint :usage_event_id
      t.bigint :scribe_session_id

      t.timestamps
    end

    add_index :credit_transactions, :account_id
    add_index :credit_transactions, %i[usage_event_id txn_type], unique: true,
              name: "index_credit_transactions_on_usage_event_and_type"
  end
end
