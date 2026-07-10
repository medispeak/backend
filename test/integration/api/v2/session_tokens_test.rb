require "test_helper"

module Api
  module V2
    class SessionTokensTest < ActionDispatch::IntegrationTest
      setup do
        Rails.cache.clear if Rails.cache.respond_to?(:clear)

        @account = create(:account)
        @user = create(:user, account: @account)
        @token = create(:api_token, user: @user, account: @account)
        @headers = { "Authorization" => "Bearer #{@token.raw_token}" }

        @session = create(:scribe_session, account: @account, api_token: @token, user: @user)

        @prev_openai_token = ENV["OPENAI_ACCESS_TOKEN"]
        ENV["OPENAI_ACCESS_TOKEN"] = "test-key"
        stub_openai!
      end

      teardown do
        Rails.cache.clear if Rails.cache.respond_to?(:clear)
        ENV["OPENAI_ACCESS_TOKEN"] = @prev_openai_token
      end

      # --- Minting (account token only) -------------------------------------

      test "POST /:id/tokens with the account bearer returns 201 with token + expiry" do
        post "/api/v2/scribe_sessions/#{@session.id}/tokens", headers: @headers
        assert_response :created
        body = JSON.parse(response.body)
        assert body["token"].start_with?("mss_")
        assert body["expires_at"].present?
        assert Scribe::SessionToken.verify(body["token"]), "minted token must verify"
      end

      test "minting a token for another account's session returns 404" do
        other_account = create(:account)
        foreign = create(:scribe_session, account: other_account)

        post "/api/v2/scribe_sessions/#{foreign.id}/tokens", headers: @headers
        assert_response :not_found
        assert_equal "session_not_found", JSON.parse(response.body).dig("error", "code")
      end

      test "minting a token with a session token (not an account token) returns 401" do
        session_token, = Scribe::SessionToken.mint(@session)

        post "/api/v2/scribe_sessions/#{@session.id}/tokens",
             headers: { "Authorization" => "Bearer #{session_token}" }
        assert_response :unauthorized
      end

      # --- Scope: what a session token CAN reach (its own session) ----------

      test "a session token reads GET /:id for its own session" do
        session_token, = Scribe::SessionToken.mint(@session)

        get "/api/v2/scribe_sessions/#{@session.id}",
            headers: { "Authorization" => "Bearer #{session_token}" }
        assert_response :accepted
        assert_equal @session.id, JSON.parse(response.body)["id"]
      end

      test "a session token drives audio then commit for its own session" do
        session_token, = Scribe::SessionToken.mint(@session)
        auth = { "Authorization" => "Bearer #{session_token}" }

        post "/api/v2/scribe_sessions/#{@session.id}/audio",
             params: { audio: audio_upload }, headers: auth
        assert_response :ok
        assert_equal "uploading", JSON.parse(response.body)["status"]

        post "/api/v2/scribe_sessions/#{@session.id}/commit", headers: auth
        assert_response :accepted

        assert_equal "completed", @session.reload.status
      end

      # --- Scope: what a session token CANNOT reach -------------------------

      test "a session token is rejected on account-wide surfaces (index, config)" do
        session_token, = Scribe::SessionToken.mint(@session)
        auth = { "Authorization" => "Bearer #{session_token}" }

        get "/api/v2/scribe_sessions", headers: auth
        assert_response :unauthorized

        get "/api/v2/config", headers: auth
        assert_response :unauthorized

        get "/api/v2/usage", headers: auth
        assert_response :unauthorized
      end

      test "a session token cannot reach another session's :id" do
        other = create(:scribe_session, account: @account, api_token: @token, user: @user)
        session_token, = Scribe::SessionToken.mint(@session)

        get "/api/v2/scribe_sessions/#{other.id}",
            headers: { "Authorization" => "Bearer #{session_token}" }
        # find_session only resolves the token's own sid; a different id is
        # out of scope and (like a cross-account account-token request) 404s.
        assert_response :not_found
        assert_equal "session_not_found", JSON.parse(response.body).dig("error", "code")
      end

      test "an expired session token is rejected" do
        expired, = Scribe::SessionToken.mint(@session, ttl: -1.second)
        auth = { "Authorization" => "Bearer #{expired}" }

        get "/api/v2/scribe_sessions/#{@session.id}", headers: auth
        assert_response :unauthorized
      end

      private

      def audio_upload
        file = Tempfile.new([ "clip", ".mp3" ])
        file.binmode
        file.write("ID3fake-audio-bytes")
        file.rewind
        Rack::Test::UploadedFile.new(file.path, "audio/mpeg")
      end

      def stub_openai!
        stub_request(:post, %r{https://api\.openai\.com/v1/audio/transcriptions})
          .to_return(
            status: 200,
            headers: { "Content-Type" => "application/json" },
            body: { text: "patient reports headache", language: "en" }.to_json
          )

        stub_request(:post, %r{https://api\.openai\.com/v1/chat/completions})
          .to_return(
            status: 200,
            headers: { "Content-Type" => "application/json" },
            body: {
              choices: [
                {
                  message: { content: { complaint: "headache" }.to_json },
                  finish_reason: "stop"
                }
              ],
              usage: { prompt_tokens: 10, completion_tokens: 5, total_tokens: 15 }
            }.to_json
          )
      end
    end
  end
end
