require "test_helper"

class ApiTokenTest < ActiveSupport::TestCase
  test "generates raw token, digest, and prefix on create" do
    token = create(:api_token)
    assert token.raw_token.start_with?("msk_live_")
    assert_equal ApiToken.digest_for(token.raw_token), token.token_digest
    assert_equal token.raw_token[0, 12], token.token_prefix
  end

  test "does not persist the raw token in a queryable form beyond the digest" do
    token = create(:api_token)
    reloaded = ApiToken.find(token.id)
    assert_nil reloaded.raw_token, "raw token is reveal-once, not reloaded"
  end

  test "derives account from the user" do
    user = create(:user)
    token = create(:api_token, user: user)
    assert_equal user.account, token.account
  end

  test "authenticate resolves an active token from its raw value" do
    token = create(:api_token)
    assert_equal token, ApiToken.authenticate(token.raw_token)
  end

  test "authenticate returns nil for an unknown token" do
    assert_nil ApiToken.authenticate("msk_live_does_not_exist")
  end

  test "authenticate returns nil for blank input" do
    assert_nil ApiToken.authenticate("")
    assert_nil ApiToken.authenticate(nil)
  end

  test "authenticate returns nil for an expired token" do
    token = create(:api_token, expires_at: 1.hour.ago)
    assert_nil ApiToken.authenticate(token.raw_token)
  end

  test "authenticate returns nil for an inactive token" do
    token = create(:api_token)
    token.update_column(:active, false)
    assert_nil ApiToken.authenticate(token.raw_token)
  end
end
