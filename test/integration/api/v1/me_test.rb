require "test_helper"

class Api::V1::MeTest < ActionDispatch::IntegrationTest
  setup do
    @token = create(:api_token)
    @user = @token.user
    @headers = { "Authorization" => "Bearer #{@token.raw_token}" }
  end

  test "returns exactly the id, email, and account_id allowlist" do
    get "/api/v1/me", headers: @headers

    assert_response :success
    body = JSON.parse(response.body)
    assert_equal %w[account_id email id], body.keys.sort
    assert_equal @user.id, body["id"]
    assert_equal @user.email, body["email"]
    assert_equal @user.account_id, body["account_id"]
  end

  test "never exposes credential or privilege fields" do
    get "/api/v1/me", headers: @headers

    body = JSON.parse(response.body)
    assert_not body.key?("encrypted_password")
    assert_not body.key?("reset_password_token")
    assert_not body.key?("reset_password_sent_at")
    assert_not body.key?("admin")
  end

  test "unauthenticated request is rejected" do
    get "/api/v1/me"

    assert_response :unauthorized
  end
end
