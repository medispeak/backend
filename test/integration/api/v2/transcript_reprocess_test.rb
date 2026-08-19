require "test_helper"

module Api
  module V2
    class TranscriptReprocessTest < ActionDispatch::IntegrationTest
      setup do
        Rails.cache.clear if Rails.cache.respond_to?(:clear)

        @account = create(:account)
        @user = create(:user, account: @account)
        @token = create(:api_token, user: @user, account: @account)
        @headers = { "Authorization" => "Bearer #{@token.raw_token}" }

        @template = create(:template)
        @page = create(:page, template: @template, prompt: "Extract clinical data")
        create(:form_field, page: @page, title: "complaint", friendly_name: "Complaint", field_type: "string")

        @prev_openai_token = ENV["OPENAI_ACCESS_TOKEN"]
        ENV["OPENAI_ACCESS_TOKEN"] = "test-key"
        stub_openai!(structured: { complaint: "headache" })

        post "/api/v2/scribe_sessions",
             params: { outputs: [ { type: "form", page_id: @page.id } ], mode: "consultation" }.to_json,
             headers: @headers.merge("Content-Type" => "application/json")
        @session_id = JSON.parse(response.body)["id"]

        post "/api/v2/scribe_sessions/#{@session_id}/audio", params: { audio: audio_upload }, headers: @headers
        post "/api/v2/scribe_sessions/#{@session_id}/commit", headers: @headers
        assert_response :accepted

        get "/api/v2/scribe_sessions/#{@session_id}", headers: @headers
        assert_equal "completed", JSON.parse(response.body)["status"]
      end

      teardown do
        Rails.cache.clear if Rails.cache.respond_to?(:clear)
        ENV["OPENAI_ACCESS_TOKEN"] = @prev_openai_token
      end

      test "editing the transcript re-runs structuring without re-running ASR" do
        first_structuring_events = UsageEvent.where(scribe_session_id: @session_id, function: "structuring").count
        assert_equal 1, first_structuring_events

        stub_openai!(structured: { complaint: "migraine" })

        patch "/api/v2/scribe_sessions/#{@session_id}/transcript",
              params: { text: "patient reports migraine" }.to_json,
              headers: @headers.merge("Content-Type" => "application/json")
        assert_response :accepted

        get "/api/v2/scribe_sessions/#{@session_id}", headers: @headers
        body = JSON.parse(response.body)
        assert_equal "completed", body["status"]
        assert_equal "patient reports migraine", body.dig("transcript", "text")
        assert_equal({ "complaint" => "migraine" }, body.dig("outputs", 0, "result"))

        # ASR did not re-run (still exactly one transcription call/event), and
        # the reprocess billed as a second, distinct structuring attempt.
        assert_not_requested :post, %r{https://api\.openai\.com/v1/audio/transcriptions}
        assert_equal 2, UsageEvent.where(scribe_session_id: @session_id, function: "structuring").count
      end

      test "rejects an empty transcript" do
        patch "/api/v2/scribe_sessions/#{@session_id}/transcript",
              params: { text: "" }.to_json,
              headers: @headers.merge("Content-Type" => "application/json")
        assert_response :unprocessable_entity
        assert_equal "validation_error", JSON.parse(response.body).dig("error", "code")
      end

      test "rejects reprocessing a session that is not in a terminal status" do
        patch "/api/v2/scribe_sessions/999999/transcript",
              params: { text: "does not matter" }.to_json,
              headers: @headers.merge("Content-Type" => "application/json")
        assert_response :not_found

        session = create(:scribe_session, account: @account, api_token: @token, user: @user, status: "uploading")
        create(:transcript, scribe_session: session)

        patch "/api/v2/scribe_sessions/#{session.id}/transcript",
              params: { text: "does not matter" }.to_json,
              headers: @headers.merge("Content-Type" => "application/json")
        assert_response :conflict
        assert_equal "validation_error", JSON.parse(response.body).dig("error", "code")
      end

      test "402s when the account has insufficient credit, without resetting outputs" do
        create(:account_credit, account: @account, balance: 0)

        patch "/api/v2/scribe_sessions/#{@session_id}/transcript",
              params: { text: "patient reports migraine" }.to_json,
              headers: @headers.merge("Content-Type" => "application/json")
        assert_response :payment_required
        assert_equal "insufficient_credit", JSON.parse(response.body).dig("error", "code")

        session = ScribeSession.find(@session_id)
        assert_equal "completed", session.status
        assert_equal "patient reports headache", session.transcript.text
      end

      private

      def audio_upload
        file = Tempfile.new([ "clip", ".mp3" ])
        file.binmode
        file.write("ID3fake-audio-bytes")
        file.rewind
        Rack::Test::UploadedFile.new(file.path, "audio/mpeg")
      end

      def stub_openai!(structured:)
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
                  message: { content: structured.to_json },
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
