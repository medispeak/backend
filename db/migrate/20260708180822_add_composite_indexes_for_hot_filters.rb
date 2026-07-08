class AddCompositeIndexesForHotFilters < ActiveRecord::Migration[8.0]
  def change
    # GET /api/v2/usage filters usage_events by (account_id, status='finalized').
    add_index :usage_events, [ :account_id, :status ],
              name: "index_usage_events_on_account_id_and_status",
              if_not_exists: true

    # GET /api/v2/scribe_sessions filters by account_id and orders by created_at DESC.
    add_index :scribe_sessions, [ :account_id, :created_at ],
              name: "index_scribe_sessions_on_account_id_and_created_at",
              if_not_exists: true
  end
end
