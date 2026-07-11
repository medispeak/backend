require "test_helper"
require "mocha/minitest"

module Api
  module V2
    # Exercises POST :id/realtime_token — the backend mints an OpenAI ephemeral
    # client secret the browser uses to connect directly to the realtime
    # transcription API. Gated behind SCRIBE_REALTIME (OFF -> 404).
    class RealtimeTokenTest < ActionDispatch::IntegrationTest
      CLIENT_SECRETS_URL = "https://api.openai.com/v1/realtime/client_secrets".freeze

      setup do
        Rails.cache.clear if Rails.cache.respond_to?(:clear)
        @account = create(:account)
        @user = create(:user, account: @account)
        @token = create(:api_token, user: @user, account: @account)
        @session = create(:scribe_session, account: @account, api_token: @token, user: @user, language: "ml")
        @session_token, = Scribe::SessionToken.mint(@session)
        @auth = { "Authorization" => "Bearer #{@session_token}" }

        @prev = ENV["OPENAI_ACCESS_TOKEN"]
        ENV["OPENAI_ACCESS_TOKEN"] = "sk-test"
        Scribe::Realtime.stubs(:enabled?).returns(true)
      end

      teardown do
        ENV["OPENAI_ACCESS_TOKEN"] = @prev
        Rails.cache.clear if Rails.cache.respond_to?(:clear)
      end

      def url
        "/api/v2/scribe_sessions/#{@session.id}/realtime_token"
      end

      def stub_mint(client_secret: "ek_realtime_abc", expires_at: 1_800_000_600)
        stub_request(:post, CLIENT_SECRETS_URL).to_return(
          status: 200, headers: { "Content-Type" => "application/json" },
          body: { client_secret: client_secret, expires_at: expires_at }.to_json
        )
      end

      test "mints an ephemeral token and returns the browser connect config" do
        stub_mint
        post url, headers: @auth
        assert_response :created

        body = JSON.parse(response.body)
        assert_equal "openai", body["provider"]
        assert_equal "ek_realtime_abc", body["token"]
        assert_equal "gpt-4o-transcribe", body["model"]
        assert_equal "https://api.openai.com/v1/realtime/calls", body["url"]
        assert_equal "realtime", body.dig("session", "type")
        assert_equal "gpt-4o-transcribe", body.dig("session", "audio", "input", "transcription", "model")

        # The session's language hint is forwarded, and the account key (not the
        # ephemeral token) authorizes the mint.
        assert_requested(:post, CLIENT_SECRETS_URL) do |req|
          req.headers["Authorization"] == "Bearer sk-test" &&
            JSON.parse(req.body).dig("session", "audio", "input", "transcription", "language") == "ml"
        end
      end

      test "accepts the nested { client_secret: { value } } response shape" do
        stub_request(:post, CLIENT_SECRETS_URL).to_return(
          status: 200, headers: { "Content-Type" => "application/json" },
          body: { client_secret: { value: "ek_nested", expires_at: 1 } }.to_json
        )
        post url, headers: @auth
        assert_response :created
        assert_equal "ek_nested", JSON.parse(response.body)["token"]
      end

      test "with SCRIBE_REALTIME off the endpoint 404s and mints nothing" do
        Scribe::Realtime.stubs(:enabled?).returns(false)
        post url, headers: @auth
        assert_response :not_found
        assert_not_requested :post, CLIENT_SECRETS_URL
      end

      test "a provider error surfaces as realtime_unavailable" do
        stub_request(:post, CLIENT_SECRETS_URL).to_return(status: 401, body: "bad key")
        post url, headers: @auth
        assert_response :unprocessable_entity
        assert_equal "realtime_unavailable", JSON.parse(response.body).dig("error", "code")
      end

      test "a foreign session token cannot mint a token for another session" do
        other = create(:scribe_session, account: create(:account))
        other_tok, = Scribe::SessionToken.mint(other)
        post url, headers: { "Authorization" => "Bearer #{other_tok}" }
        assert_response :not_found
      end
    end
  end
end
