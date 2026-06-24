class CreateAccounts < ActiveRecord::Migration[8.0]
  def change
    create_table :accounts do |t|
      t.string :name, null: false
      t.string :status, null: false, default: "active"
      t.jsonb :settings, null: false, default: {}
      t.string :webhook_secret
      t.string :default_callback_url

      t.timestamps
    end
  end
end
