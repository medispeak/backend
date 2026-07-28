# Flexible tenancy tree: an account may have a parent account (org -> program
# -> facility, up to Account::MAX_DEPTH levels). Purely additive — every
# existing account (including all personal auto-created accounts) remains a
# parentless root, so behavior is unchanged until an admin sets a parent.
class AddParentToAccounts < ActiveRecord::Migration[8.0]
  def change
    add_reference :accounts, :parent, null: true, index: true,
                  foreign_key: { to_table: :accounts }
  end
end
