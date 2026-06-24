require "test_helper"

module Api
  module V2
    class ScribeSessionsTest < ActionDispatch::IntegrationTest
      setup do
        Rails.cache.clear if Rails.cache.respond_to?(:clear)

        @account = create(:account)
        @user = create(:user, account: @account)
        @token = create(:api_token, user: @user, account: @account)
        @headers = { "Authorization" => "Bearer #{@token.raw_token}" }

        @template = create(:template)
        @page = create(:page, template: @template, prompt: "Extract clinical data")
        create(:form_field, page: @page, title: "complaint", friendly_name: "Complaint", field_type: "string")

        # The orchestrator runs ASR (whisper-1) then structuring (gpt-4o-mini)
        # against the ENV-default OpenAI endpoint. Provide a token so the adapter
        # builds, and stub both endpoints.
        @prev_openai_token = ENV["OPENAI_ACCESS_TOKEN"]
        ENV["OPENAI_ACCESS_TOKEN"] = "test-key"
        stub_openai!
      end

      teardown do
        Rails.cache.clear if Rails.cache.respond_to?(:clear)
        ENV["OPENAI_ACCESS_TOKEN"] = @prev_openai_token
      end

      test "full lifecycle: create -> audio -> commit -> completed show" do
        # create
        post "/api/v2/scribe_sessions",
             params: { outputs: [ { type: "form", page_id: @page.id } ], mode: "consultation" }.to_json,
             headers: @headers.merge("Content-Type" => "application/json")
        assert_response :created
        body = JSON.parse(response.body)
        assert_equal "created", body["status"]
        session_id = body["id"]
        assert_equal 1, body["outputs"].size
        assert_equal "form", body.dig("outputs", 0, "type")

        # audio upload
        post "/api/v2/scribe_sessions/#{session_id}/audio",
             params: { audio: audio_upload },
             headers: @headers
        assert_response :ok
        assert_equal "uploading", JSON.parse(response.body)["status"]

        # commit (inline job runs the orchestrator synchronously)
        post "/api/v2/scribe_sessions/#{session_id}/commit",
             headers: @headers
        assert_response :accepted

        # show: completed with output result + key "errors"
        get "/api/v2/scribe_sessions/#{session_id}", headers: @headers
        assert_response :ok
        shown = JSON.parse(response.body)
        assert_equal "completed", shown["status"]
        output = shown["outputs"].first
        assert output.key?("errors"), "output JSON must expose result_errors as 'errors'"
        assert output.key?("result")
        assert_equal({ "complaint" => "headache" }, output["result"])
      end

      test "cross-account access returns 404" do
        session = create(:scribe_session, account: @account, api_token: @token, user: @user)

        other_account = create(:account)
        other_user = create(:user, account: other_account)
        other_token = create(:api_token, user: other_user, account: other_account)

        get "/api/v2/scribe_sessions/#{session.id}",
            headers: { "Authorization" => "Bearer #{other_token.raw_token}" }
        assert_response :not_found
        assert_equal "session_not_found", JSON.parse(response.body).dig("error", "code")
      end

      test "unauthenticated request returns 401" do
        get "/api/v2/scribe_sessions"
        assert_response :unauthorized
      end

      test "create with invalid output type returns 422" do
        post "/api/v2/scribe_sessions",
             params: { outputs: [ { type: "bogus" } ] }.to_json,
             headers: @headers.merge("Content-Type" => "application/json")
        assert_response :unprocessable_entity
        assert_equal "validation_error", JSON.parse(response.body).dig("error", "code")
      end

      test "create form output with missing page returns 422" do
        post "/api/v2/scribe_sessions",
             params: { outputs: [ { type: "form", page_id: 999_999 } ] }.to_json,
             headers: @headers.merge("Content-Type" => "application/json")
        assert_response :unprocessable_entity
        assert_equal "validation_error", JSON.parse(response.body).dig("error", "code")
      end

      test "idempotent create only persists one session for the same key + body" do
        payload = { outputs: [ { type: "form", page_id: @page.id } ] }.to_json
        idem_headers = @headers.merge(
          "Content-Type" => "application/json",
          "Idempotency-Key" => "abc-123"
        )

        assert_difference -> { ScribeSession.count }, 1 do
          post "/api/v2/scribe_sessions", params: payload, headers: idem_headers
          assert_response :created
          first_id = JSON.parse(response.body)["id"]

          post "/api/v2/scribe_sessions", params: payload, headers: idem_headers
          assert_response :created
          second_id = JSON.parse(response.body)["id"]

          assert_equal first_id, second_id, "replay must return the stored response"
        end
      end

      test "idempotent create with a different body returns 409 conflict" do
        idem_headers = @headers.merge(
          "Content-Type" => "application/json",
          "Idempotency-Key" => "conflict-1"
        )

        post "/api/v2/scribe_sessions",
             params: { outputs: [ { type: "transcript" } ] }.to_json,
             headers: idem_headers
        assert_response :created

        post "/api/v2/scribe_sessions",
             params: { outputs: [ { type: "form", page_id: @page.id } ] }.to_json,
             headers: idem_headers
        assert_response :conflict
      end

      test "audio upload on an expired session returns 410" do
        session = create(:scribe_session, account: @account, api_token: @token,
                                          user: @user, expires_at: 1.hour.ago)
        post "/api/v2/scribe_sessions/#{session.id}/audio",
             params: { audio: audio_upload },
             headers: @headers
        assert_response :gone
        assert_equal "session_expired", JSON.parse(response.body).dig("error", "code")
      end

      test "index lists account-scoped sessions" do
        create(:scribe_session, account: @account, api_token: @token, user: @user)

        other_account = create(:account)
        create(:scribe_session, account: other_account)

        get "/api/v2/scribe_sessions", headers: @headers
        assert_response :ok
        sessions = JSON.parse(response.body)["scribe_sessions"]
        assert_equal 1, sessions.size
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
