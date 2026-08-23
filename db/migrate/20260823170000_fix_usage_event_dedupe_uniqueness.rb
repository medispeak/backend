class FixUsageEventDedupeUniqueness < ActiveRecord::Migration[8.1]
  # The old unique index was (api_token_id, dedupe_key). api_token_id is NULL
  # for any session created without an API token — every playground run — and
  # Postgres treats each NULL as distinct, so for those rows the index enforced
  # nothing: a redelivered job inserted a second usage_event and QuotaGuard
  # deducted a second time. COALESCE collapses them into one bucket. (NULLS NOT
  # DISTINCT says this directly but needs Postgres 15; the floor here is 14.)
  INDEX_NAME = "index_usage_events_on_token_and_dedupe_key".freeze

  def up
    # Rows that already collide are real charges. Keep the ledger row and clear
    # only its key, so the index can be built without deleting billing history.
    execute(<<~SQL.squish)
      UPDATE usage_events SET dedupe_key = NULL
      WHERE id IN (
        SELECT id FROM (
          SELECT id, ROW_NUMBER() OVER (
            PARTITION BY COALESCE(api_token_id, 0), dedupe_key ORDER BY id
          ) AS position
          FROM usage_events
          WHERE dedupe_key IS NOT NULL
        ) ranked
        WHERE ranked.position > 1
      )
    SQL

    remove_index :usage_events, name: INDEX_NAME
    execute(<<~SQL.squish)
      CREATE UNIQUE INDEX #{INDEX_NAME}
      ON usage_events (COALESCE(api_token_id, 0), dedupe_key)
      WHERE dedupe_key IS NOT NULL
    SQL
  end

  def down
    remove_index :usage_events, name: INDEX_NAME
    add_index :usage_events, [ :api_token_id, :dedupe_key ], name: INDEX_NAME, unique: true
  end
end
