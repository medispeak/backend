class CreateScribeTranscriptSegments < ActiveRecord::Migration[8.0]
  def change
    create_table :scribe_transcript_segments do |t|
      t.references :scribe_session, null: false, foreign_key: true
      t.integer :seq, null: false
      t.string :content_type
      t.text :text
      t.string :language
      t.string :status, null: false, default: "pending"
      t.string :provider
      t.string :model
      t.float :duration_seconds
      t.datetime :transcribed_at
      t.timestamps
    end
    add_index :scribe_transcript_segments, [ :scribe_session_id, :seq ], unique: true
  end
end
