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

      test "committing twice runs the pipeline once and charges each output once" do
        # create -> audio -> commit (inline job runs the pipeline to completion)
        post "/api/v2/scribe_sessions",
             params: { outputs: [ { type: "form", page_id: @page.id } ], mode: "consultation" }.to_json,
             headers: @headers.merge("Content-Type" => "application/json")
        assert_response :created
        session_id = JSON.parse(response.body)["id"]

        post "/api/v2/scribe_sessions/#{session_id}/audio",
             params: { audio: audio_upload },
             headers: @headers
        assert_response :ok

        post "/api/v2/scribe_sessions/#{session_id}/commit", headers: @headers
        assert_response :accepted

        get "/api/v2/scribe_sessions/#{session_id}", headers: @headers
        assert_equal "completed", JSON.parse(response.body)["status"]

        first_count = UsageEvent.where(scribe_session_id: session_id).count
        assert first_count.positive?

        # Second commit from a completed session is rejected — the pipeline does
        # not re-run and nothing new is charged.
        post "/api/v2/scribe_sessions/#{session_id}/commit", headers: @headers
        assert_response :conflict
        assert_equal "validation_error", JSON.parse(response.body).dig("error", "code")

        assert_equal first_count, UsageEvent.where(scribe_session_id: session_id).count
      end

      test "commit is rejected with 402 when the account has insufficient credit" do
        # create
        post "/api/v2/scribe_sessions",
             params: { outputs: [ { type: "form", page_id: @page.id } ], mode: "consultation" }.to_json,
             headers: @headers.merge("Content-Type" => "application/json")
        assert_response :created
        session_id = JSON.parse(response.body)["id"]

        # audio upload
        post "/api/v2/scribe_sessions/#{session_id}/audio",
             params: { audio: audio_upload },
             headers: @headers
        assert_response :ok

        # The setup account has no AccountCredit (unlimited); give it a zero
        # balance so the commit hold cannot be covered.
        create(:account_credit, account: @account, balance: 0)

        post "/api/v2/scribe_sessions/#{session_id}/commit", headers: @headers
        assert_response :payment_required
        assert_equal "insufficient_credit", JSON.parse(response.body).dig("error", "code")

        # No job ran (jobs are inline in test) and nothing was metered.
        session = ScribeSession.find(session_id)
        assert_not_includes %w[processing completed partial failed], session.status
        assert_equal "uploading", session.status
        assert_equal 0, UsageEvent.where(scribe_session_id: session_id).count
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

      test "create form output with inline fields returns 201 and stores them" do
        post "/api/v2/scribe_sessions",
             params: {
               outputs: [
                 { type: "form", fields: [ { key: "hr", label: "Heart Rate", type: "number" } ] }
               ]
             }.to_json,
             headers: @headers.merge("Content-Type" => "application/json")
        assert_response :created
        session_id = JSON.parse(response.body)["id"]

        output = ScribeSession.find(session_id).scribe_outputs.first
        assert_nil output.page_id
        assert_equal "hr", output.inline_fields.first["key"]
        assert_equal "number", output.inline_fields.first["type"]
      end

      test "create form output with neither page_id nor fields returns 422" do
        post "/api/v2/scribe_sessions",
             params: { outputs: [ { type: "form" } ] }.to_json,
             headers: @headers.merge("Content-Type" => "application/json")
        assert_response :unprocessable_entity
        assert_equal "validation_error", JSON.parse(response.body).dig("error", "code")
      end

      test "create form output with both page_id and fields returns 422" do
        post "/api/v2/scribe_sessions",
             params: {
               outputs: [
                 { type: "form", page_id: @page.id,
                   fields: [ { key: "hr", label: "Heart Rate", type: "number" } ] }
               ]
             }.to_json,
             headers: @headers.merge("Content-Type" => "application/json")
        assert_response :unprocessable_entity
        assert_equal "validation_error", JSON.parse(response.body).dig("error", "code")
      end

      test "create form output with invalid inline fields returns 422" do
        post "/api/v2/scribe_sessions",
             params: {
               outputs: [
                 { type: "form", fields: [ { key: "sx", type: "single_select" } ] }
               ]
             }.to_json,
             headers: @headers.merge("Content-Type" => "application/json")
        assert_response :unprocessable_entity
        assert_equal "validation_error", JSON.parse(response.body).dig("error", "code")
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

      test "audio upload rejects a non-audio content type" do
        session = create(:scribe_session, account: @account, api_token: @token, user: @user)

        post "/api/v2/scribe_sessions/#{session.id}/audio",
             params: { audio: non_audio_upload },
             headers: @headers

        assert_response :unprocessable_entity
        assert_equal "validation_error", JSON.parse(response.body).dig("error", "code")
        assert_not session.reload.audio_files.attached?, "a rejected upload must not be persisted"
      end

      test "audio upload rejects an oversized file" do
        session = create(:scribe_session, account: @account, api_token: @token, user: @user)

        post "/api/v2/scribe_sessions/#{session.id}/audio",
             params: { audio: oversized_audio_upload },
             headers: @headers

        assert_response :unprocessable_entity
        assert_equal "audio_upload_failed", JSON.parse(response.body).dig("error", "code")
        assert_not session.reload.audio_files.attached?, "a rejected upload must not be persisted"
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

      test "index does not run an extra query per session (no N+1 on outputs)" do
        s1 = create(:scribe_session, account: @account, api_token: @token, user: @user)
        create(:scribe_output, scribe_session: s1)

        q1 = count_ar_queries { get "/api/v2/scribe_sessions", headers: @headers }
        assert_response :ok
        body = JSON.parse(response.body)
        assert body["scribe_sessions"].all? { |s| s.key?("outputs") }, "output shape changed"

        3.times do
          s = create(:scribe_session, account: @account, api_token: @token, user: @user)
          create(:scribe_output, scribe_session: s)
        end

        q2 = count_ar_queries { get "/api/v2/scribe_sessions", headers: @headers }
        assert_response :ok

        assert_equal q1, q2,
          "query count grew with more sessions -> N+1 not fixed (got #{q1} then #{q2})"
      end

      test "index respects limit and offset params" do
        3.times { create(:scribe_session, account: @account, api_token: @token, user: @user) }

        get "/api/v2/scribe_sessions", params: { limit: 2 }, headers: @headers
        assert_response :ok
        assert_equal 2, JSON.parse(response.body)["scribe_sessions"].size

        get "/api/v2/scribe_sessions", params: { limit: 2, offset: 2 }, headers: @headers
        assert_response :ok
        assert_equal 1, JSON.parse(response.body)["scribe_sessions"].size
      end

      test "index caps the page size at the maximum" do
        now = Time.current
        rows = Array.new(105) { { account_id: @account.id, status: "created", created_at: now, updated_at: now } }
        ScribeSession.insert_all(rows)

        get "/api/v2/scribe_sessions", params: { limit: 9999 }, headers: @headers
        assert_response :ok
        assert_equal 100, JSON.parse(response.body)["scribe_sessions"].size
      end

      private

      # Counts real ActiveRecord SELECT/INSERT/UPDATE/DELETE queries issued inside the
      # block, ignoring schema reflection, cache hits, and transaction control
      # statements. Used to prove the list endpoint does not N+1.
      def count_ar_queries
        count = 0
        callback = lambda do |_name, _start, _finish, _id, payload|
          next if payload[:cached]
          next if payload[:name] == "SCHEMA"
          next if payload[:sql].to_s =~ /\A\s*(BEGIN|COMMIT|ROLLBACK|SAVEPOINT|RELEASE|SET|SHOW)\b/i

          count += 1
        end
        ActiveSupport::Notifications.subscribed(callback, "sql.active_record") { yield }
        count
      end

      def audio_upload
        file = Tempfile.new([ "clip", ".mp3" ])
        file.binmode
        file.write("ID3fake-audio-bytes")
        file.rewind
        Rack::Test::UploadedFile.new(file.path, "audio/mpeg")
      end

      def non_audio_upload
        file = Tempfile.new([ "payload", ".zip" ])
        file.binmode
        file.write("PKnot-a-real-zip")
        file.rewind
        Rack::Test::UploadedFile.new(file.path, "application/zip")
      end

      # A sparse file just over the size ceiling — declared as valid audio so the
      # size check (not the content-type check) is what rejects it.
      def oversized_audio_upload
        file = Tempfile.new([ "big", ".mp3" ])
        file.binmode
        file.truncate(ScribeSession::MAX_AUDIO_BYTES + 1)
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
