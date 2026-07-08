class MakeApiTokensTokenNullable < ActiveRecord::Migration[8.0]
  def change
    change_column_null :api_tokens, :token, true
  end
end
