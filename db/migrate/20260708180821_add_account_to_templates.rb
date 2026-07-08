class AddAccountToTemplates < ActiveRecord::Migration[8.0]
  # Nullable: templates have no pre-existing owner association, so legacy rows
  # keep account_id NULL and are treated as admin-only-editable shared config.
  # New user-created templates get the creator's account (plan 013, Path A).
  def change
    add_reference :templates, :account, null: true, foreign_key: true, index: true
  end
end
