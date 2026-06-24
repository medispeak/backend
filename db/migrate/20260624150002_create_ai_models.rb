class CreateAiModels < ActiveRecord::Migration[8.0]
  def change
    create_table :ai_models do |t|
      t.references :ai_provider, null: false, foreign_key: true
      t.string :api_model_id, null: false
      t.string :display_name
      t.jsonb :capabilities, null: false, default: {}
      t.boolean :active, null: false, default: true

      t.timestamps
    end
  end
end
