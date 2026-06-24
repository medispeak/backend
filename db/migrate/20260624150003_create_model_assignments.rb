class CreateModelAssignments < ActiveRecord::Migration[8.0]
  def change
    create_table :model_assignments do |t|
      t.string :scope_type, null: false # System | Account | Page
      t.bigint :scope_id                 # null for System
      t.string :function, null: false    # asr | structuring | combined
      t.references :ai_model, null: false, foreign_key: true
      t.bigint :fallback_ai_model_id
      t.jsonb :options, null: false, default: {}

      t.timestamps
    end

    add_index :model_assignments, %i[scope_type scope_id function], unique: true,
              name: "index_model_assignments_on_scope_and_function"
    add_foreign_key :model_assignments, :ai_models, column: :fallback_ai_model_id
  end
end
