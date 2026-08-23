require "test_helper"

module Api
  module V2
    # POST /api/v2/scribe_sessions/:id/retry — re-running a FINISHED session.
    class RetryTest < ActionDispatch::IntegrationTest
      include PdfFixtures

      setup do
        Rails.cache.clear if Rails.cache.respond_to?(:clear)

        @account = create(:account)
        @user = create(:user, account: @account)
        @token = create(:api_token, user: @user, account: @account)
        @headers = { "Authorization" => "Bearer #{@token.raw_token}" }
        @json = @headers.merge("Content-Type" => "application/json")

        @template = create(:template)
        @page = create(:page, template: @template, prompt: "Extract clinical data")
        create(:form_field, page: @page, title: "complaint", friendly_name: "Complaint", field_type: "string")

        @prev_openai_token = ENV["OPENAI_ACCESS_TOKEN"]
        ENV["OPENAI_ACCESS_TOKEN"] = "test-key"
        stub_openai!(complaint: "headache")
      end

      teardown do
        Rails.cache.clear if Rails.cache.respond_to?(:clear)
        ENV["OPENAI_ACCESS_TOKEN"] = @prev_openai_token
      end

      # ------------------------------------------------------------- structuring

      test "structuring retry re-fills a COMPLETED session, which commit cannot" do
        id = run_session_to_completion

        # Commit is closed to a completed session — this is the gap retry fills.
        post "/api/v2/scribe_sessions/#{id}/commit", headers: @headers
        assert_response :conflict

        stub_openai!(complaint: "migraine")
        post "/api/v2/scribe_sessions/#{id}/retry",
             params: { scope: "structuring" }.to_json, headers: @json
        assert_response :accepted

        get "/api/v2/scribe_sessions/#{id}", headers: @headers
        assert_response :ok
        output = JSON.parse(response.body)["outputs"].first
        assert_equal({ "complaint" => "migraine" }, output["result"])
        assert_equal 1, output["attempt"]
      end

      test "a corrected transcript is what the re-fill reads, and ASR is not re-run" do
        id = run_session_to_completion
        session = ScribeSession.find(id)
        asr_calls_before = session.usage_events.where(function: "asr").count

        stub_structuring!(complaint: "500mg metformin")
        post "/api/v2/scribe_sessions/#{id}/retry",
             params: { scope: "structuring", transcript: "patient on 500mg metformin" }.to_json,
             headers: @json
        assert_response :accepted

        session.reload
        transcript = session.transcript
        assert_equal "patient on 500mg metformin", transcript.text
        # The ASR original survives as the record of what the model actually heard.
        assert_equal "patient reports headache", transcript.original_text
        assert transcript.edited_at.present?
        assert_equal @user.id, transcript.edited_by_user_id
        assert_equal asr_calls_before, session.usage_events.where(function: "asr").count,
                     "a structuring retry must not re-run (or re-bill) ASR"

        get "/api/v2/scribe_sessions/#{id}", headers: @headers
        body = JSON.parse(response.body)
        assert_equal true, body.dig("transcript", "edited")
        assert_equal({ "complaint" => "500mg metformin" }, body.dig("outputs", 0, "result"))
      end

      test "a transcript correction also refreshes the transcript output it echoes" do
        id = run_session_to_completion(outputs: [
          { type: "form", page_id: @page.id }, { type: "transcript" }
        ])

        stub_structuring!(complaint: "headache")
        post "/api/v2/scribe_sessions/#{id}/retry",
             params: { scope: "structuring", transcript: "corrected text" }.to_json,
             headers: @json
        assert_response :accepted

        get "/api/v2/scribe_sessions/#{id}", headers: @headers
        outputs = JSON.parse(response.body)["outputs"]
        echo = outputs.find { |o| o["type"] == "transcript" }
        assert_equal "corrected text", echo.dig("result", "text"),
                     "a transcript output is an echo; leaving it stale would contradict the top-level transcript"
      end

      test "a plain structuring retry leaves the transcript output alone" do
        id = run_session_to_completion(outputs: [
          { type: "form", page_id: @page.id }, { type: "transcript" }
        ])

        post "/api/v2/scribe_sessions/#{id}/retry",
             params: { scope: "structuring" }.to_json, headers: @json
        assert_response :accepted

        get "/api/v2/scribe_sessions/#{id}", headers: @headers
        outputs = JSON.parse(response.body)["outputs"]
        assert_equal 0, outputs.find { |o| o["type"] == "transcript" }["attempt"],
                     "nothing the echo reads changed, so it must not count an attempt"
        assert_equal 1, outputs.find { |o| o["type"] == "form" }["attempt"]
      end

      # ------------------------------------------------------------ transcription

      test "transcription retry re-derives the transcript from the audio" do
        id = run_session_to_completion
        assert_equal "patient reports headache", ScribeSession.find(id).transcript.text

        stub_openai!(complaint: "fever", transcript: "patient reports fever")
        post "/api/v2/scribe_sessions/#{id}/retry",
             params: { scope: "transcription" }.to_json, headers: @json
        assert_response :accepted

        session = ScribeSession.find(id)
        assert_equal "patient reports fever", session.transcript.text
        assert_equal 1, Transcript.where(scribe_session_id: id).count,
                     "the replaced transcript must not linger alongside the new one"
      end

      test "transcription retry re-transcribes the segments a live recording left behind" do
        session = create(:scribe_session, account: @account, api_token: @token, user: @user)
        auth = { "Authorization" => "Bearer #{Scribe::SessionToken.mint(session).first}" }

        post "/api/v2/scribe_sessions/#{session.id}/audio/segments",
             params: { seq: 0, segment: segment_upload }, headers: auth
        assert_response :ok
        post "/api/v2/scribe_sessions/#{session.id}/audio",
             params: { audio: audio_upload }, headers: auth
        assert_response :ok
        post "/api/v2/scribe_sessions/#{session.id}/commit", headers: auth
        assert_response :accepted
        assert_equal "patient reports headache", session.reload.transcript.text
        segment_asr_before = session.usage_events.where(function: "asr").count

        stub_openai!(complaint: "fever", transcript: "patient reports fever")
        post "/api/v2/scribe_sessions/#{session.id}/retry",
             params: { scope: "transcription" }.to_json,
             headers: { "Authorization" => auth["Authorization"], "Content-Type" => "application/json" }
        assert_response :accepted

        session.reload
        segment = session.transcript_segments.find_by(seq: 0)
        assert_equal "done", segment.status
        assert_equal 1, segment.attempt, "a re-transcribed segment needs its own attempt for metering"
        assert_equal "patient reports fever", segment.text
        assert_equal "patient reports fever", session.transcript.text,
                     "the assembled transcript must come from the re-transcribed segments"
        assert_equal segment_asr_before + 1, session.usage_events.where(function: "asr").count,
                     "the second physical ASR call on this segment must be billed, not swallowed"
      end

      test "transcription retry re-runs OCR on a document session and bills the second attempt" do
        post "/api/v2/scribe_sessions",
             params: { modality: "document", outputs: [ { type: "form", page_id: @page.id } ] }.to_json,
             headers: @json
        id = JSON.parse(response.body)["id"]

        stub_ocr!(text: "Hemoglobin | 13.5 g/dL")
        post "/api/v2/scribe_sessions/#{id}/documents", params: { document: pdf_upload }, headers: @headers
        assert_response :ok
        post "/api/v2/scribe_sessions/#{id}/commit", headers: @headers
        assert_response :accepted
        assert_includes ScribeSession.find(id).transcript.text, "Hemoglobin"

        stub_ocr!(text: "Hemoglobin | 9.1 g/dL")
        post "/api/v2/scribe_sessions/#{id}/retry",
             params: { scope: "transcription" }.to_json, headers: @json
        assert_response :accepted

        session = ScribeSession.find(id)
        assert_includes session.transcript.text, "9.1"
        events = session.usage_events.where(function: "ocr")
        assert_equal 2, events.count, "the retry's OCR call is real provider spend and must be billed"
        assert_equal 2, events.map(&:dedupe_key).uniq.size
      end

      # ----------------------------------------------------------------- metering

      test "each retry is billed: attempt-scoped dedupe keys, no swallowed collision" do
        id = run_session_to_completion
        session = ScribeSession.find(id)
        assert_equal 1, session.usage_events.where(function: "structuring").count

        2.times do
          post "/api/v2/scribe_sessions/#{id}/retry",
               params: { scope: "structuring" }.to_json, headers: @json
          assert_response :accepted
        end

        events = session.reload.usage_events.where(function: "structuring")
        assert_equal 3, events.count,
                     "a retry that collides on dedupe_key is provider spend billed to nobody"
        assert_equal 3, events.map(&:dedupe_key).uniq.size
      end

      test "history keeps the answer a retry replaces" do
        id = run_session_to_completion
        stub_structuring!(complaint: "migraine")
        post "/api/v2/scribe_sessions/#{id}/retry",
             params: { scope: "structuring" }.to_json, headers: @json
        assert_response :accepted

        output = ScribeSession.find(id).scribe_outputs.first
        assert_equal({ "complaint" => "migraine" }, output.result)
        assert_equal 1, output.previous_results.size
        assert_equal({ "complaint" => "headache" }, output.previous_results.first["result"])
        assert_equal 0, output.previous_results.first["attempt"]
      end

      # --------------------------------------------------------------- rejections

      test "transcript with scope=transcription is rejected rather than silently discarded" do
        id = run_session_to_completion
        post "/api/v2/scribe_sessions/#{id}/retry",
             params: { scope: "transcription", transcript: "corrected" }.to_json, headers: @json
        assert_response :unprocessable_entity
        assert_match(/discard the correction/, JSON.parse(response.body).dig("error", "message"))
        assert_equal "completed", ScribeSession.find(id).status, "a rejected retry must not move the session"
      end

      test "unknown scope, blank transcript and an oversized transcript are all 422" do
        id = run_session_to_completion

        post "/api/v2/scribe_sessions/#{id}/retry",
             params: { scope: "everything" }.to_json, headers: @json
        assert_response :unprocessable_entity

        post "/api/v2/scribe_sessions/#{id}/retry",
             params: { scope: "structuring", transcript: "   " }.to_json, headers: @json
        assert_response :unprocessable_entity

        oversized = "a" * (Scribe::RetryPreparer::MAX_TRANSCRIPT_CHARS + 1)
        post "/api/v2/scribe_sessions/#{id}/retry",
             params: { scope: "structuring", transcript: oversized }.to_json, headers: @json
        assert_response :unprocessable_entity
      end

      test "a session that never ran cannot be retried" do
        post "/api/v2/scribe_sessions",
             params: { outputs: [ { type: "form", page_id: @page.id } ] }.to_json, headers: @json
        id = JSON.parse(response.body)["id"]

        post "/api/v2/scribe_sessions/#{id}/retry",
             params: { scope: "structuring" }.to_json, headers: @json
        assert_response :conflict
      end

      test "retries are capped" do
        id = run_session_to_completion

        Scribe::RetryPreparer::MAX_ATTEMPTS.times do
          post "/api/v2/scribe_sessions/#{id}/retry",
               params: { scope: "structuring" }.to_json, headers: @json
          assert_response :accepted
        end

        post "/api/v2/scribe_sessions/#{id}/retry",
             params: { scope: "structuring" }.to_json, headers: @json
        assert_response :too_many_requests
        assert_equal "retry_limit_exceeded", JSON.parse(response.body).dig("error", "code")
        assert_equal "completed", ScribeSession.find(id).status
      end

      # The reset is destructive, so it must not happen for a retry that is then
      # refused: the session would read "completed" with empty outputs.
      test "a retry refused for credit leaves the previous answer intact" do
        id = run_session_to_completion
        session = ScribeSession.find(id)
        create(:account_credit, account: @account, balance: 0)

        post "/api/v2/scribe_sessions/#{id}/retry",
             params: { scope: "transcription" }.to_json, headers: @json
        assert_response :payment_required
        assert_equal "insufficient_credit", JSON.parse(response.body).dig("error", "code")

        session.reload
        assert_equal "completed", session.status
        assert_equal "patient reports headache", session.transcript.text
        output = session.scribe_outputs.first
        assert_equal "success", output.status
        assert_equal({ "complaint" => "headache" }, output.result)
        assert_equal 0, output.attempt
      end

      test "a session from another account is not retryable" do
        id = run_session_to_completion
        other = create(:api_token, user: create(:user, account: create(:account)))

        post "/api/v2/scribe_sessions/#{id}/retry",
             params: { scope: "structuring" }.to_json,
             headers: { "Authorization" => "Bearer #{other.raw_token}", "Content-Type" => "application/json" }
        assert_response :not_found
      end

      test "an expired session is still retryable" do
        id = run_session_to_completion
        ScribeSession.where(id: id).update_all(expires_at: 1.hour.ago)

        post "/api/v2/scribe_sessions/#{id}/retry",
             params: { scope: "structuring" }.to_json, headers: @json
        assert_response :accepted
      end

      # A scoped session token is the browser/SDK credential: whoever can write
      # the session can retry it.
      test "a scoped session token can retry its own session" do
        id = run_session_to_completion
        token, = Scribe::SessionToken.mint(ScribeSession.find(id))

        post "/api/v2/scribe_sessions/#{id}/retry",
             params: { scope: "structuring", transcript: "corrected by the clinician" }.to_json,
             headers: { "Authorization" => "Bearer #{token}", "Content-Type" => "application/json" }
        assert_response :accepted
        assert_equal "corrected by the clinician", ScribeSession.find(id).transcript.text
      end

      private

      def run_session_to_completion(outputs: nil)
        outputs ||= [ { type: "form", page_id: @page.id } ]
        post "/api/v2/scribe_sessions", params: { outputs: outputs }.to_json, headers: @json
        assert_response :created
        id = JSON.parse(response.body)["id"]

        post "/api/v2/scribe_sessions/#{id}/audio", params: { audio: audio_upload }, headers: @headers
        assert_response :ok

        post "/api/v2/scribe_sessions/#{id}/commit", headers: @headers
        assert_response :accepted
        assert_equal "completed", ScribeSession.find(id).status
        id
      end

      # A standalone webm transcription segment (the live-recording path).
      def segment_upload
        file = Tempfile.new([ "segment", ".webm" ])
        file.binmode
        file.write("segment bytes")
        file.rewind
        Rack::Test::UploadedFile.new(file.path, "audio/webm")
      end

      def audio_upload
        Rack::Test::UploadedFile.new(
          StringIO.new("fake audio bytes"), "audio/mpeg", original_filename: "consult.mp3"
        )
      end

      def stub_openai!(complaint:, transcript: "patient reports headache")
        stub_request(:post, %r{https://api\.openai\.com/v1/audio/transcriptions})
          .to_return(
            status: 200,
            headers: { "Content-Type" => "application/json" },
            body: { text: transcript, language: "en" }.to_json
          )
        stub_structuring!(complaint: complaint)
      end

      # OCR and structuring share the chat endpoint; the OCR call is the one that
      # returns plain text, so both stubs have to be in place for a document run.
      def stub_ocr!(text:)
        stub_request(:post, %r{https://api\.openai\.com/v1/chat/completions})
          .to_return(
            status: 200,
            headers: { "Content-Type" => "application/json" },
            body: {
              choices: [ { message: { content: text }, finish_reason: "stop" } ],
              usage: { prompt_tokens: 900, completion_tokens: 120 }
            }.to_json
          )
      end

      def pdf_upload
        file = Tempfile.new([ "report", ".pdf" ])
        file.binmode
        file.write(minimal_pdf(pages: 1))
        file.rewind
        Rack::Test::UploadedFile.new(file.path, "application/pdf")
      end

      def stub_structuring!(complaint:)
        stub_request(:post, %r{https://api\.openai\.com/v1/chat/completions})
          .to_return(
            status: 200,
            headers: { "Content-Type" => "application/json" },
            body: {
              choices: [ { message: { content: { complaint: complaint }.to_json }, finish_reason: "stop" } ],
              usage: { prompt_tokens: 10, completion_tokens: 5, total_tokens: 15 }
            }.to_json
          )
      end
    end
  end
end
