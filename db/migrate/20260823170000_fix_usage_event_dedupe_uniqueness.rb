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
  #
  # usage_events takes a write on every provider call, so this runs live-safe:
  # the backfill is batched and the indexes are built and dropped CONCURRENTLY,
  # which needs to be outside a transaction. The new index is created BEFORE the
  # old one is dropped so uniqueness is never unenforced in between.
  disable_ddl_transaction!

  OLD_NAME = "index_usage_events_on_token_and_dedupe_key".freeze
  NEW_NAME = "index_usage_events_on_dedupe_key".freeze
  BATCH_SIZE = 10_000

  def up
    clear_duplicate_keys!

    add_index :usage_events, :dedupe_key, name: NEW_NAME, unique: true,
              where: "dedupe_key IS NOT NULL",
              algorithm: :concurrently, if_not_exists: true
    remove_index :usage_events, name: OLD_NAME, algorithm: :concurrently, if_exists: true
  end

  def down
    add_index :usage_events, [ :api_token_id, :dedupe_key ], name: OLD_NAME, unique: true,
              algorithm: :concurrently, if_not_exists: true
    remove_index :usage_events, name: NEW_NAME, algorithm: :concurrently, if_exists: true
  end

  private

  # Rows that already collide are real charges. Keep the ledger row and clear
  # only its key, so the index can be built without deleting billing history.
  # Batched: one unbounded UPDATE over this table would hold row locks on the
  # hot billing path for as long as it ran.
  def clear_duplicate_keys!
    loop do
      cleared = execute(<<~SQL.squish).cmd_tuples
        UPDATE usage_events SET dedupe_key = NULL
        WHERE id IN (
          SELECT id FROM (
            SELECT id, ROW_NUMBER() OVER (PARTITION BY dedupe_key ORDER BY id) AS position
            FROM usage_events
            WHERE dedupe_key IS NOT NULL
          ) ranked
          WHERE ranked.position > 1
          LIMIT #{BATCH_SIZE}
        )
      SQL

      break if cleared.zero?
    end
  end
end
