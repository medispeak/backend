require "test_helper"

module Api
  module V2
    class UsageTest < ActionDispatch::IntegrationTest
      setup do
        @account = create(:account)
        @user = create(:user, account: @account)
        @token = create(:api_token, user: @user, account: @account)
        @headers = { "Authorization" => "Bearer #{@token.raw_token}" }
      end

      test "aggregates finalized usage events for the account" do
        UsageEvent.create!(
          account: @account, api_token: @token, function: "structuring", status: "finalized",
          model: "gpt-4o-mini", total_tokens: 100, audio_seconds: 0, cost: 0.01
        )
        UsageEvent.create!(
          account: @account, api_token: @token, function: "asr", status: "finalized",
          model: "whisper-1", total_tokens: 0, audio_seconds: 30, cost: 0.02
        )
        # Pending event must be excluded from the summary.
        UsageEvent.create!(
          account: @account, api_token: @token, function: "structuring", status: "pending",
          model: "gpt-4o-mini", total_tokens: 50, audio_seconds: 0, cost: 0.99
        )

        get "/api/v2/usage", headers: @headers
        assert_response :ok

        body = JSON.parse(response.body)
        assert_in_delta 0.03, body["total_cost"], 0.0001
        assert_equal 100, body["total_tokens"]
        assert_in_delta 30.0, body["total_audio_seconds"], 0.0001

        models = body["by_model"].map { |m| m["model"] }
        assert_includes models, "gpt-4o-mini"
        assert_includes models, "whisper-1"
      end

      test "returns zeros when there is no usage" do
        get "/api/v2/usage", headers: @headers
        assert_response :ok

        body = JSON.parse(response.body)
        assert_equal 0.0, body["total_cost"]
        assert_equal 0, body["total_tokens"]
        assert_equal 0.0, body["total_audio_seconds"]
        assert_equal [], body["by_model"]
      end

      test "requires authentication" do
        get "/api/v2/usage"
        assert_response :unauthorized
      end
    end
  end
end
