# Backfills usage_events.user_id from the session's user (the acting clinician)
# for events that predate the denormalized column. Idempotent (only touches
# NULL user_id rows) and batched, so it is safe to run on a live table.
class BackfillUsageEventUserIds < ActiveRecord::Migration[8.0]
  disable_ddl_transaction!

  def up
    loop do
      updated = execute(<<~SQL).cmd_tuples
        UPDATE usage_events
        SET user_id = scribe_sessions.user_id
        FROM scribe_sessions
        WHERE usage_events.id IN (
          SELECT usage_events.id FROM usage_events
          JOIN scribe_sessions ON scribe_sessions.id = usage_events.scribe_session_id
          WHERE usage_events.user_id IS NULL
            AND scribe_sessions.user_id IS NOT NULL
          LIMIT 10000
        )
        AND scribe_sessions.id = usage_events.scribe_session_id
      SQL
      break if updated.zero?
    end
  end

  def down
    # The column is dropped by reverting AddUserToUsageEvents; nothing to undo.
  end
end
