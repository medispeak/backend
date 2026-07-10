class AddInlineFieldsToScribeOutputs < ActiveRecord::Migration[8.0]
  def change
    add_column :scribe_outputs, :inline_fields, :jsonb
  end
end
