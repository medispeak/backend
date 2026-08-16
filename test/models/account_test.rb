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

  # settings is edited as JSON text in the admin UI. A String slipping through
  # (Rails persists it as a JSON string scalar) makes rack_attack read
  # `"{\"rpm\": 300}"["rpm"]` -> "rpm" -> to_i -> 0 rpm: every request for the
  # account throttled. Same trap as ModelAssignment#options; same coercion.
  test "settings coerces JSON text into a Hash and rejects non-objects" do
    account = create(:account, settings: '{"rpm": 300}')
    assert_equal({ "rpm" => 300 }, account.reload.settings)
    assert_equal "object", Account.connection.select_value(
      "SELECT jsonb_typeof(settings) FROM accounts WHERE id = #{account.id}"
    )
    assert_equal({}, create(:account, settings: "").reload.settings)

    bad = build(:account, settings: '"{}"')
    assert_not bad.valid?
    assert_includes bad.errors[:settings], "must be a JSON object"
  end

  test "destroying an account destroys its api tokens" do
    token = create(:api_token)
    account = token.account
    assert_difference("ApiToken.count", -1) { account.destroy }
  end
end
