class CreateAiProviders < ActiveRecord::Migration[8.0]
  def change
    create_table :ai_providers do |t|
      t.string :name, null: false
      t.string :kind, null: false # openai_compatible | anthropic | gemini
      t.string :base_url
      t.text :api_key # encrypted via Active Record Encryption
      t.string :organization_id
      t.integer :request_timeout, null: false, default: 120
      t.boolean :active, null: false, default: true

      t.timestamps
    end
  end
end
