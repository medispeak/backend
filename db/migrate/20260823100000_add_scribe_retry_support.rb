# Retry support for POST /api/v2/scribe_sessions/:id/retry.
#
# `attempt` feeds metering: usage_events is UNIQUE on (api_token_id,
# dedupe_key), and an attempt-agnostic key made a rerun collide — swallowed by
# the best-effort meter rescue, so real provider spend was billed to nobody
# (the same bug fixed earlier for OCR). `previous_results` keeps the answer a
# retry replaces; the transcript columns record a human correction without
# losing what ASR actually produced.
class AddScribeRetrySupport < ActiveRecord::Migration[8.1]
  def up
    add_column :scribe_outputs, :attempt, :integer, default: 0, null: false
    add_column :scribe_outputs, :previous_results, :jsonb, default: [], null: false
    add_column :scribe_transcript_segments, :attempt, :integer, default: 0, null: false

    add_column :transcripts, :edited_at, :datetime
    add_column :transcripts, :edited_by_user_id, :bigint
    add_column :transcripts, :original_text, :text

    # has_one :transcript had no database backing; retry destroys + rewrites
    # the row, and a bug there must not silently leave two.
    guard_duplicate_transcripts!
    remove_index :transcripts, column: :scribe_session_id,
                 name: "index_transcripts_on_scribe_session_id"
    add_index :transcripts, :scribe_session_id, unique: true,
              name: "index_transcripts_on_scribe_session_id"
  end

  def down
    remove_index :transcripts, column: :scribe_session_id,
                 name: "index_transcripts_on_scribe_session_id"
    add_index :transcripts, :scribe_session_id, name: "index_transcripts_on_scribe_session_id"

    remove_column :transcripts, :original_text
    remove_column :transcripts, :edited_by_user_id
    remove_column :transcripts, :edited_at
    remove_column :scribe_transcript_segments, :attempt
    remove_column :scribe_outputs, :previous_results
    remove_column :scribe_outputs, :attempt
  end

  private

  # Raises rather than picking a survivor: which of two transcripts is the real
  # one for a consultation is a clinical judgement, not a migration's.
  def guard_duplicate_transcripts!
    dupes = select_values(<<~SQL)
      SELECT scribe_session_id FROM transcripts
      GROUP BY scribe_session_id HAVING COUNT(*) > 1
    SQL
    return if dupes.empty?

    raise ActiveRecord::MigrationError,
          "transcripts has duplicate rows for scribe_session_id(s) #{dupes.join(', ')}; " \
          "resolve which transcript is authoritative before adding the unique index"
  end
end
