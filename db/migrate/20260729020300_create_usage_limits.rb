# Usage limits attach to any tenancy-tree node and are enforced as pure-read
# admission gates over usage_events (Metering::LimitGuard) — deliberately NOT a
# second ledger. scope "subtree" caps the aggregate usage of the node's whole
# subtree; "per_user" caps each individual user under the node.
class CreateUsageLimits < ActiveRecord::Migration[8.0]
  def change
    create_table :usage_limits do |t|
      t.bigint :account_id, null: false
      t.string :scope, null: false     # subtree | per_user
      t.string :metric, null: false    # tokens | cost
      t.string :period, null: false    # daily | monthly
      t.decimal :limit_value, precision: 16, scale: 6, null: false
      t.timestamps
      t.index [ :account_id, :scope, :metric, :period ], unique: true,
              name: "index_usage_limits_on_account_scope_metric_period"
    end
    add_foreign_key :usage_limits, :accounts
  end
end
