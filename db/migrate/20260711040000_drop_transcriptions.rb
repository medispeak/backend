# Removes the legacy v1 `transcriptions` table. The v1 transcription API and its
# model/controllers/views were deleted; the model-agnostic v2 scribe pipeline
# uses `scribe_sessions` + `transcripts` + `scribe_transcript_segments` instead.
class DropTranscriptions < ActiveRecord::Migration[8.0]
  def up
    # Detach any orphaned ActiveStorage records for the removed model, then drop.
    execute(<<~SQL)
      DELETE FROM active_storage_attachments WHERE record_type = 'Transcription';
    SQL
    drop_table :transcriptions, if_exists: true
  end

  def down
    raise ActiveRecord::IrreversibleMigration,
          "The legacy v1 transcriptions table was intentionally removed."
  end
end
