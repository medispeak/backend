class CreateScribeOutputs < ActiveRecord::Migration[8.0]
  def change
    create_table :scribe_outputs do |t|
      t.bigint :scribe_session_id, null: false
      t.string :output_type, null: false # transcript | form | note
      t.bigint :page_id
      t.string :template_ref
      t.jsonb :context, null: false, default: {}
      t.string :status, null: false, default: "pending"
      t.jsonb :result, null: false, default: {}
      # NOTE: named `result_errors` (not `errors`) because a column named
      # `errors` collides with ActiveModel's reserved `errors` method and raises
      # ActiveRecord::DangerousAttributeError at class-load time, making the
      # model impossible to instantiate. The v2 API serializer maps this to
      # `errors` in the per-output JSON response.
      t.jsonb :result_errors, null: false, default: []

      t.timestamps
    end

    add_index :scribe_outputs, :scribe_session_id
    add_foreign_key :scribe_outputs, :scribe_sessions
  end
end
