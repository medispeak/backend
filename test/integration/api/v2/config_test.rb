require "test_helper"

module Api
  module V2
    class ConfigTest < ActionDispatch::IntegrationTest
      setup do
        @account = create(:account, settings: { "rpm" => 90 })
        @user = create(:user, account: @account)
        @token = create(:api_token, user: @user, account: @account)
        @headers = { "Authorization" => "Bearer #{@token.raw_token}" }
      end

      test "returns discovery payload for an authenticated account" do
        create(:template, name: "Active Template", archived: false)
        create(:template, name: "Archived Template", archived: true)

        get "/api/v2/config", headers: @headers
        assert_response :ok

        body = JSON.parse(response.body)
        assert_equal %w[en hi ta auto], body["languages"]
        assert_equal 90, body.dig("limits", "rpm")

        names = body["templates"].map { |t| t["name"] }
        assert_includes names, "Active Template"
        refute_includes names, "Archived Template"
      end

      test "falls back to default rpm when not set in account settings" do
        account = create(:account, settings: {})
        user = create(:user, account: account)
        token = create(:api_token, user: user, account: account)

        get "/api/v2/config", headers: { "Authorization" => "Bearer #{token.raw_token}" }
        assert_response :ok
        assert_equal 120, JSON.parse(response.body).dig("limits", "rpm")
      end

      test "requires authentication" do
        get "/api/v2/config"
        assert_response :unauthorized
      end
    end
  end
end
