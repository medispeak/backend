require "test_helper"

module Api
  module V2
    # ocr_mode: "extract_and_structure" — one vision call straight to the form
    # fields, no extracted text. The saving IS the transcript, so every gate
    # here exists to make sure nobody relying on the text loses it silently.
    class CombinedExtractionTest < ActionDispatch::IntegrationTest
      CHAT_URL = "https://api.openai.com/v1/chat/completions".freeze

      setup do
        @account = create(:account)
        @user = create(:user, account: @account)
        @token = create(:api_token, user: @user, account: @account)
        @headers = { "Authorization" => "Bearer #{@token.raw_token}" }
        @prev = ENV["OPENAI_ACCESS_TOKEN"]
        ENV["OPENAI_ACCESS_TOKEN"] = "test-key"

        @page = create(:page)
        create(:form_field, page: @page, title: "hemoglobin", friendly_name: "Hemoglobin", field_type: "string")
      end

      teardown { ENV["OPENAI_ACCESS_TOKEN"] = @prev }

      # A vision model that can also return schema-valid JSON, assigned to :ocr
      # with the combined mode switched on.
      def assign_combined_ocr!(options: { "ocr_mode" => "extract_and_structure" }, capabilities: nil)
        model = create(:ai_model, api_model_id: "gpt-4o-mini", capabilities: capabilities || {
          "supports_vision" => true, "supports_pdf" => true,
          "can_structure" => true, "supports_json_schema" => true
        })
        create(:model_assignment, scope_type: "System", scope_id: nil, function: "ocr",
                                  ai_model: model, options: options)
        model
      end

      def stub_structured(fields = { hemoglobin: "13.5" }, usage: { prompt_tokens: 1500, completion_tokens: 150 })
        stub_request(:post, CHAT_URL).to_return(
          status: 200, headers: { "Content-Type" => "application/json" },
          body: { choices: [ { message: { content: fields.to_json }, finish_reason: "stop" } ],
                  usage: usage }.to_json
        )
      end

      def document_session(outputs: [ { type: "form", page_id: nil } ], pages: 1)
        outputs = outputs.map { |o| o[:page_id].nil? && o[:type] == "form" ? o.merge(page_id: @page.id) : o }
        post "/api/v2/scribe_sessions",
             params: { modality: "document", outputs: outputs }.to_json,
             headers: @headers.merge("Content-Type" => "application/json")
        id = JSON.parse(response.body)["id"]
        post "/api/v2/scribe_sessions/#{id}/documents",
             params: { document: pdf_upload(pages: pages) }, headers: @headers
        assert_response :ok
        id
      end

      test "one provider call fills the form and the run completes" do
        assign_combined_ocr!
        stub_structured
        id = document_session

        post "/api/v2/scribe_sessions/#{id}/commit", headers: @headers
        assert_response :accepted

        get "/api/v2/scribe_sessions/#{id}", headers: @headers
        body = JSON.parse(response.body)
        assert_equal "completed", body["status"]
        assert_equal "13.5", body["outputs"].sole.dig("result", "hemoglobin")
        # Exactly one round-trip — that is the whole point.
        assert_requested :post, CHAT_URL, times: 1
      end

      test "no extracted text is emitted, and the transcript says so" do
        assign_combined_ocr!
        stub_structured
        id = document_session
        post "/api/v2/scribe_sessions/#{id}/commit", headers: @headers

        get "/api/v2/scribe_sessions/#{id}", headers: @headers
        body = JSON.parse(response.body)
        # A present object with a null text, NOT a bare null: null already means
        # "not ready yet", and a client polling on it against a terminal 200
        # would spin forever.
        assert body.key?("transcript")
        assert_not_nil body["transcript"]
        assert_nil body.dig("transcript", "text")
        assert_nil ScribeSession.find(id).transcript.text
      end

      test "it is metered once as ocr, carrying the page count" do
        assign_combined_ocr!
        stub_structured
        id = document_session(pages: 2)
        post "/api/v2/scribe_sessions/#{id}/commit", headers: @headers

        events = UsageEvent.where(scribe_session_id: id)
        assert_equal 1, events.count
        event = events.sole
        assert_equal "ocr", event.function
        assert_equal "finalized", event.status
        assert_equal 2, event.pages, "the per-page quantity must survive"
        assert_equal "#{id}:ocr:0", event.dedupe_key
        # No structuring event: there was no second call to meter.
        assert_equal 0, UsageEvent.where(scribe_session_id: id, function: "structuring").count
      end

      # ── the gates: each falls back to the two-call path, never a 4xx ──────

      test "a declared transcript output keeps the two-call path" do
        assign_combined_ocr!
        # OCR text, then structuring JSON — two calls.
        stub_request(:post, CHAT_URL).to_return(
          { status: 200, headers: { "Content-Type" => "application/json" },
            body: { choices: [ { message: { content: "Hemoglobin 13.5" }, finish_reason: "stop" } ],
                    usage: { prompt_tokens: 900, completion_tokens: 100 } }.to_json },
          { status: 200, headers: { "Content-Type" => "application/json" },
            body: { choices: [ { message: { content: { hemoglobin: "13.5" }.to_json }, finish_reason: "stop" } ],
                    usage: { prompt_tokens: 200, completion_tokens: 20 } }.to_json }
        )
        id = document_session(outputs: [ { type: "transcript" }, { type: "form", page_id: nil } ])

        post "/api/v2/scribe_sessions/#{id}/commit", headers: @headers

        session = ScribeSession.find(id)
        assert_equal "completed", session.status
        assert_includes session.transcript.text, "Hemoglobin", "the text must still exist"
        assert_requested :post, CHAT_URL, times: 2
      end

      test "more than one output keeps the two-call path" do
        assign_combined_ocr!
        second = create(:page, template: @page.template)
        create(:form_field, page: second, title: "wbc", friendly_name: "WBC", field_type: "string")
        stub_request(:post, CHAT_URL).to_return(
          status: 200, headers: { "Content-Type" => "application/json" },
          body: { choices: [ { message: { content: { hemoglobin: "13.5" }.to_json }, finish_reason: "stop" } ],
                  usage: { prompt_tokens: 900, completion_tokens: 100 } }.to_json
        )
        id = document_session(outputs: [ { type: "form", page_id: @page.id },
                                         { type: "form", page_id: second.id } ])

        post "/api/v2/scribe_sessions/#{id}/commit", headers: @headers

        # The split path: an extracted transcript exists, and there was more
        # than one call. Not pinned to an exact count — a schema-repair re-ask
        # legitimately adds one and is not what this test is about.
        assert_not_nil ScribeSession.find(id).transcript.text
        assert_requested :post, CHAT_URL, at_least_times: 3
      end

      test "a report longer than the page limit keeps the two-call path" do
        assign_combined_ocr!
        stub_request(:post, CHAT_URL).to_return(
          status: 200, headers: { "Content-Type" => "application/json" },
          body: { choices: [ { message: { content: { hemoglobin: "13.5" }.to_json }, finish_reason: "stop" } ],
                  usage: { prompt_tokens: 900, completion_tokens: 100 } }.to_json
        )
        id = document_session(pages: Scribe::Orchestrator::MAX_COMBINED_PAGES + 1)

        post "/api/v2/scribe_sessions/#{id}/commit", headers: @headers

        assert_requested :post, CHAT_URL, times: 2
        assert_not_nil ScribeSession.find(id).transcript.text
      end

      test "a model that cannot return structured JSON keeps the two-call path" do
        assign_combined_ocr!(capabilities: { "supports_vision" => true, "supports_pdf" => true })
        stub_request(:post, CHAT_URL).to_return(
          status: 200, headers: { "Content-Type" => "application/json" },
          body: { choices: [ { message: { content: { hemoglobin: "13.5" }.to_json }, finish_reason: "stop" } ],
                  usage: { prompt_tokens: 900, completion_tokens: 100 } }.to_json
        )
        id = document_session

        post "/api/v2/scribe_sessions/#{id}/commit", headers: @headers

        assert_requested :post, CHAT_URL, times: 2
      end

      test "the mode is off by default" do
        assign_combined_ocr!(options: {})
        stub_request(:post, CHAT_URL).to_return(
          status: 200, headers: { "Content-Type" => "application/json" },
          body: { choices: [ { message: { content: { hemoglobin: "13.5" }.to_json }, finish_reason: "stop" } ],
                  usage: { prompt_tokens: 900, completion_tokens: 100 } }.to_json
        )
        id = document_session

        post "/api/v2/scribe_sessions/#{id}/commit", headers: @headers
        assert_requested :post, CHAT_URL, times: 2
      end

      # ── failure ──────────────────────────────────────────────────────────

      test "a failed combined call fails the session with a generic message" do
        assign_combined_ocr!
        stub_request(:post, CHAT_URL).to_return(status: 500, body: "boom")
        id = document_session

        post "/api/v2/scribe_sessions/#{id}/commit", headers: @headers

        session = ScribeSession.find(id)
        assert_equal "failed", session.status
        assert_equal [ "failure" ], session.scribe_outputs.map(&:status).uniq
        assert_nil session.transcript, "nothing was extracted, so no stub transcript"
      end

      # An unusable-but-billed 200 must still reach the ledger, exactly as the
      # split path does.
      test "a billed-but-unusable combined attempt is recorded as failed" do
        assign_combined_ocr!
        stub_request(:post, CHAT_URL).to_return(
          status: 200, headers: { "Content-Type" => "application/json" },
          body: { choices: [ { message: { content: "half" }, finish_reason: "length" } ],
                  usage: { prompt_tokens: 1500, completion_tokens: 4096 } }.to_json
        )
        id = document_session

        post "/api/v2/scribe_sessions/#{id}/commit", headers: @headers

        assert_equal "failed", ScribeSession.find(id).status
        event = UsageEvent.find_by(scribe_session_id: id, function: "ocr")
        assert event, "the billed attempt was absorbed silently"
        assert_equal "failed", event.status
        assert_equal 4096, event.output_tokens
      end

      private

      def pdf_upload(pages: 1)
        file = Tempfile.new([ "report", ".pdf" ])
        file.binmode
        file.write(minimal_pdf(pages: pages))
        file.rewind
        Rack::Test::UploadedFile.new(file.path, "application/pdf")
      end

      include PdfFixtures
    end
  end
end
