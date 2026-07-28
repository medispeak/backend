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

      test "scope=subtree rolls up child-account usage; the default stays self-only" do
        facility = create(:account, parent: @account)
        create(:usage_event, account: @account, cost: 1, total_tokens: 10)
        create(:usage_event, account: facility, cost: 2, total_tokens: 20)

        get "/api/v2/usage", headers: @headers
        assert_in_delta 1.0, JSON.parse(response.body)["total_cost"], 1e-6

        get "/api/v2/usage", params: { scope: "subtree" }, headers: @headers
        body = JSON.parse(response.body)
        assert_in_delta 3.0, body["total_cost"], 1e-6
        assert_equal 30, body["total_tokens"]
      end

      test "group_by=user returns per-user sums keyed by user_id" do
        other = create(:user, account: @account)
        create(:usage_event, account: @account, user_id: @user.id, cost: 1, total_tokens: 10)
        create(:usage_event, account: @account, user_id: other.id, cost: 2, total_tokens: 20)

        get "/api/v2/usage", params: { group_by: "user" }, headers: @headers
        assert_response :ok

        by_user = JSON.parse(response.body).fetch("by_user")
        mine = by_user.find { |row| row["user_id"] == @user.id }
        assert_in_delta 1.0, mine["cost"], 1e-6
        assert_equal 10, mine["total_tokens"]
      end

      test "user_id filters to one user and 404s outside the caller's subtree" do
        other_tenant = create(:account)
        foreign_user = create(:user, account: other_tenant)
        create(:usage_event, account: @account, user_id: @user.id, cost: 1)

        get "/api/v2/usage", params: { user_id: @user.id }, headers: @headers
        assert_response :ok
        assert_in_delta 1.0, JSON.parse(response.body)["total_cost"], 1e-6

        get "/api/v2/usage", params: { user_id: foreign_user.id }, headers: @headers
        assert_response :not_found
        assert_equal "user_not_found", JSON.parse(response.body).dig("error", "code")
      end

      test "from/to bound the window" do
        create(:usage_event, account: @account, cost: 1, created_at: 10.days.ago)
        create(:usage_event, account: @account, cost: 2)

        get "/api/v2/usage", params: { from: 1.day.ago.iso8601 }, headers: @headers
        assert_in_delta 2.0, JSON.parse(response.body)["total_cost"], 1e-6

        get "/api/v2/usage", params: { to: 5.days.ago.iso8601 }, headers: @headers
        assert_in_delta 1.0, JSON.parse(response.body)["total_cost"], 1e-6
      end

      test "commit is blocked with usage_limit_exceeded and the claim reverts" do
        create(:usage_limit, account: @account, scope: "per_user", metric: "tokens",
               period: "daily", limit_value: 100)
        create(:usage_event, account: @account, user_id: @user.id, total_tokens: 100)

        session = create(:scribe_session, account: @account, api_token: @token,
                         user: @user, status: "uploading")
        session.audio_files.attach(io: StringIO.new("a"), filename: "a.mp3", content_type: "audio/mpeg")

        post "/api/v2/scribe_sessions/#{session.id}/commit", headers: @headers
        assert_response :payment_required
        assert_equal "usage_limit_exceeded", JSON.parse(response.body).dig("error", "code")
        assert_equal "uploading", session.reload.status,
                     "the commit claim must roll back so the session stays committable"
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
