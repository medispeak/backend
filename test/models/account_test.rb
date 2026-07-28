require "test_helper"

class AccountTest < ActiveSupport::TestCase
  test "valid with a name" do
    assert build(:account).valid?
  end

  test "requires a name" do
    assert_not build(:account, name: nil).valid?
  end

  test "generates a webhook_secret on create" do
    account = create(:account)
    assert account.webhook_secret.present?
  end

  test "destroying an account destroys its api tokens" do
    token = create(:api_token)
    account = token.account
    assert_difference("ApiToken.count", -1) { account.destroy }
  end
end
