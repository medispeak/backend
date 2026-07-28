# Denormalizes the acting user onto usage_events so per-user limits and
# per-user usage rollups are single-index scans instead of joins through
# scribe_sessions. No FK: usage events are an immutable ledger and must
# survive user deletion (dependent: :nullify churn) without write amplification.
class AddUserToUsageEvents < ActiveRecord::Migration[8.0]
  def change
    add_column :usage_events, :user_id, :bigint
    add_index :usage_events, [ :user_id, :created_at ]
  end
end
