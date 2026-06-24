class CreateTranscripts < ActiveRecord::Migration[8.0]
  def change
    create_table :transcripts do |t|
      t.bigint :scribe_session_id, null: false
      t.text :text
      t.string :language
      t.decimal :duration_seconds, precision: 12, scale: 3, default: 0
      t.string :provider
      t.string :model
      t.jsonb :segments, default: []
      t.jsonb :words, default: []
      t.jsonb :speakers, default: []

      t.timestamps
    end

    add_index :transcripts, :scribe_session_id
    add_foreign_key :transcripts, :scribe_sessions
  end
end
