class FixUsageEventDedupeUniqueness < ActiveRecord::Migration[8.1]
  # The old index was UNIQUE (api_token_id, dedupe_key), and api_token_id is
  # NULL for any session created without a token. Postgres treats each NULL as
  # distinct, so for those rows the index enforced nothing and a redelivered job
  # could bill the same provider call twice.
  #
  # api_token_id was never needed here: every dedupe_key is built by
  # Metering::DedupeKey and starts with the session id, so the key alone is
  # already unique. Dropping the column from the index closes the hole with one
  # fewer moving part than the index it replaces.
  OLD_NAME = "index_usage_events_on_token_and_dedupe_key".freeze
  NEW_NAME = "index_usage_events_on_dedupe_key".freeze

  def up
    # Rows that already collide are real charges. Keep the ledger row and clear
    # only its key, so the index can be built without deleting billing history.
    execute(<<~SQL.squish)
      UPDATE usage_events SET dedupe_key = NULL
      WHERE id IN (
        SELECT id FROM (
          SELECT id, ROW_NUMBER() OVER (PARTITION BY dedupe_key ORDER BY id) AS position
          FROM usage_events
          WHERE dedupe_key IS NOT NULL
        ) ranked
        WHERE ranked.position > 1
      )
    SQL

    remove_index :usage_events, name: OLD_NAME
    add_index :usage_events, :dedupe_key, name: NEW_NAME, unique: true,
              where: "dedupe_key IS NOT NULL"
  end

  def down
    remove_index :usage_events, name: NEW_NAME
    add_index :usage_events, [ :api_token_id, :dedupe_key ], name: OLD_NAME, unique: true
  end
end
