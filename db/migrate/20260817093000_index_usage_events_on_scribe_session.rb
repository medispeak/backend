# usage_events is read by scribe_session_id on every poll of a session (the
# serializer's per-session usage block), by the playground result page, and now
# by the orchestrator when it numbers OCR attempts and keys failed ones — yet
# the column carried no index, so each of those was a sequential scan of the
# whole ledger. Cheap while the table is small; a real cost the moment it isn't,
# on the hottest read path a client has.
#
# A plain (non-concurrent) add_index: the table is a few hundred rows today, so
# the write lock lasts milliseconds and the migration stays transactional.
class IndexUsageEventsOnScribeSession < ActiveRecord::Migration[8.1]
  def change
    add_index :usage_events, :scribe_session_id
  end
end
