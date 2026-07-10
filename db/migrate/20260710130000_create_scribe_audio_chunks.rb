class CreateScribeAudioChunks < ActiveRecord::Migration[8.0]
  def change
    create_table :scribe_audio_chunks do |t|
      t.references :scribe_session, null: false, foreign_key: true
      t.integer :seq, null: false
      t.boolean :final, null: false, default: false
      t.string :content_type
      t.timestamps
    end
    add_index :scribe_audio_chunks, [ :scribe_session_id, :seq ], unique: true
  end
end
