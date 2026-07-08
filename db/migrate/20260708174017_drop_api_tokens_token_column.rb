class DropApiTokensTokenColumn < ActiveRecord::Migration[8.0]
  def change
    remove_index :api_tokens, name: "index_api_tokens_on_token"
    remove_column :api_tokens, :token, :string
  end
end
