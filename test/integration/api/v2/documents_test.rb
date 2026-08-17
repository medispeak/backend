require "test_helper"
require "mocha/minitest"

module Api
  module V2
    # OCR modality end-to-end: create a document session, upload a lab report
    # (PDF/image), commit, poll. OCR runs once (vision LLM -> Transcript),
    # structuring consumes the extracted text through the unchanged output
    # loop, and metering records one :ocr event (with pages) plus one
    # :structuring event per output.
    class DocumentsTest < ActionDispatch::IntegrationTest
      include PdfFixtures

      CHAT_URL = "https://api.openai.com/v1/chat/completions".freeze

      setup do
        @account = create(:account)
        @user = create(:user, account: @account)
        @token = create(:api_token, user: @user, account: @account)
        @headers = { "Authorization" => "Bearer #{@token.raw_token}" }

        @prev_openai_token = ENV["OPENAI_ACCESS_TOKEN"]
        ENV["OPENAI_ACCESS_TOKEN"] = "test-key"
      end

      teardown do
        ENV["OPENAI_ACCESS_TOKEN"] = @prev_openai_token
      end

      test "document session: upload PDF -> commit -> extracted text + structured output" do
        # Both OCR and structuring go through chat/completions; the FIRST
        # response is the OCR extraction (plain text), the SECOND the
        # structuring JSON.
        stub_request(:post, CHAT_URL)
          .to_return(
            { status: 200, headers: { "Content-Type" => "application/json" },
              body: { choices: [ { message: { content: "Hemoglobin | 13.5 | g/dL | 12-16" }, finish_reason: "stop" } ],
                      usage: { prompt_tokens: 900, completion_tokens: 100 } }.to_json },
            { status: 200, headers: { "Content-Type" => "application/json" },
              body: { choices: [ { message: { content: { hemoglobin: "13.5" }.to_json }, finish_reason: "stop" } ],
                      usage: { prompt_tokens: 200, completion_tokens: 20 } }.to_json }
          )

        page = create(:page)
        create(:form_field, page: page, title: "hemoglobin", friendly_name: "Hemoglobin", field_type: "string")

        post "/api/v2/scribe_sessions",
             params: { modality: "document",
                       outputs: [ { type: "transcript" }, { type: "form", page_id: page.id } ] }.to_json,
             headers: @headers.merge("Content-Type" => "application/json")
        assert_response :created
        body = JSON.parse(response.body)
        assert_equal "document", body["modality"]
        session_id = body["id"]

        post "/api/v2/scribe_sessions/#{session_id}/documents",
             params: { document: pdf_upload(pages: 3) }, headers: @headers
        assert_response :ok
        assert_equal 3, JSON.parse(response.body)["pages"]

        post "/api/v2/scribe_sessions/#{session_id}/commit", headers: @headers
        assert_response :accepted

        get "/api/v2/scribe_sessions/#{session_id}", headers: @headers
        assert_response :ok
        body = JSON.parse(response.body)
        assert_equal "completed", body["status"]
        assert_includes body.dig("transcript", "text"), "Hemoglobin"
        form_output = body["outputs"].find { |o| o["type"] == "form" }
        assert_equal "13.5", form_output.dig("result", "hemoglobin")
        assert_equal 3, body.dig("usage", "pages")

        events = UsageEvent.where(scribe_session_id: session_id)
        assert_equal 1, events.where(function: "ocr").count
        assert_equal 3, events.find_by(function: "ocr").pages
        assert_equal 1, events.where(function: "structuring").count
      end

      test "an image counts as one page" do
        session_id = create_document_session
        post "/api/v2/scribe_sessions/#{session_id}/documents",
             params: { document: image_upload }, headers: @headers
        assert_response :ok
        assert_equal 1, JSON.parse(response.body)["pages"]
      end

      test "a malformed PDF is a clean 422 at upload" do
        session_id = create_document_session
        post "/api/v2/scribe_sessions/#{session_id}/documents",
             params: { document: broken_pdf_upload }, headers: @headers
        assert_response :unprocessable_entity
        assert_equal "validation_error", JSON.parse(response.body).dig("error", "code")
      end

      test "exceeding the page cap is rejected" do
        session_id = create_document_session
        post "/api/v2/scribe_sessions/#{session_id}/documents",
             params: { document: pdf_upload(pages: ScribeSession::MAX_DOCUMENT_PAGES + 1) },
             headers: @headers
        assert_response :unprocessable_entity
        assert_equal "document_upload_failed", JSON.parse(response.body).dig("error", "code")
      end

      test "a disallowed content type is rejected" do
        session_id = create_document_session
        file = Tempfile.new([ "doc", ".txt" ])
        file.write("plain text")
        file.rewind
        post "/api/v2/scribe_sessions/#{session_id}/documents",
             params: { document: Rack::Test::UploadedFile.new(file.path, "text/plain") },
             headers: @headers
        assert_response :unprocessable_entity
      end

      # ── the type is what the bytes say ───────────────────────────────────

      # The multipart Content-Type is a client claim. Active Storage stores the
      # sniffed type and the provider receives it, so counting pages by the
      # DECLARED type let a 3-page PDF calling itself image/jpeg through as one
      # page — under the cap, the hold and per-page metering — and then be OCR'd
      # as the whole PDF.
      test "a PDF declared as an image is counted and stored as a PDF" do
        session_id = create_document_session
        file = Tempfile.new([ "scan", ".jpg" ])
        file.binmode
        file.write(minimal_pdf(pages: 3))
        file.rewind

        post "/api/v2/scribe_sessions/#{session_id}/documents",
             params: { document: Rack::Test::UploadedFile.new(file.path, "image/jpeg") },
             headers: @headers

        assert_response :ok
        assert_equal 3, JSON.parse(response.body)["pages"], "counted by the declared type, not the bytes"
        assert_equal "application/pdf", ScribeSession.find(session_id).document_files.first.blob.content_type
      end

      # The mirror image: allowed on the label, disallowed in the bytes. Before
      # sniffing this passed the allowlist, then failed the model's content_type
      # validation inside the row lock and 500'd.
      test "a file whose bytes are not an allowed type is a 422 whatever it claims to be" do
        session_id = create_document_session
        file = Tempfile.new([ "scan", ".jpg" ])
        file.binmode
        file.write("GIF89a\x01\x00\x01\x00\x00\x00\x00;")
        file.rewind

        post "/api/v2/scribe_sessions/#{session_id}/documents",
             params: { document: Rack::Test::UploadedFile.new(file.path, "image/jpeg") },
             headers: @headers

        assert_response :unprocessable_entity
        body = JSON.parse(response.body)
        assert_equal "validation_error", body.dig("error", "code")
        assert_match(/image\/gif/, body.dig("error", "message"))
        assert_equal 0, ScribeSession.find(session_id).document_files.count
      end

      # ── the lock's own guards ────────────────────────────────────────────

      test "uploading to a session that has already been committed is a 409" do
        session_id = create_document_session
        post "/api/v2/scribe_sessions/#{session_id}/documents",
             params: { document: pdf_upload(pages: 1) }, headers: @headers
        assert_response :ok
        ScribeSession.find(session_id).update!(status: "processing")

        post "/api/v2/scribe_sessions/#{session_id}/documents",
             params: { document: pdf_upload(pages: 1) }, headers: @headers

        assert_response :conflict
        body = JSON.parse(response.body)
        assert_equal "validation_error", body.dig("error", "code")
        assert_match(/from status processing/, body.dig("error", "message"))
        assert_equal 1, ScribeSession.find(session_id).document_pages
      end

      test "the byte cap is enforced across separate uploads" do
        session_id = create_document_session
        # A stored blob whose recorded size sits just under the session ceiling,
        # without pushing 20 MB through the request: the cap is a sum over blob
        # byte_size, which is exactly what this exercises.
        big = ActiveStorage::Blob.create_and_upload!(
          io: StringIO.new(minimal_pdf(pages: 1)), filename: "big.pdf", content_type: "application/pdf"
        )
        ScribeSession.find(session_id).document_files.attach(big)
        big.update_column(:byte_size, ScribeSession::MAX_DOCUMENT_BYTES - 16)

        post "/api/v2/scribe_sessions/#{session_id}/documents",
             params: { document: pdf_upload(pages: 1) }, headers: @headers

        assert_response :unprocessable_entity
        body = JSON.parse(response.body)
        assert_equal "document_upload_failed", body.dig("error", "code")
        assert_match(/total documents exceed/, body.dig("error", "message"))
        assert_equal 0, ScribeSession.find(session_id).document_pages, "a rejected upload must not increment"
      end

      # ── failure surface ──────────────────────────────────────────────────

      # Extraction does more than call a provider, and an internal exception's
      # message routinely carries SQL, bucket names or paths. The session must
      # still fail cleanly (outputs failed, session failed, nothing left at
      # pending) but the client reads a generic message; the real one is logged.
      test "an internal failure during extraction fails the session with a generic client message" do
        session_id = create_document_session
        post "/api/v2/scribe_sessions/#{session_id}/documents",
             params: { document: pdf_upload(pages: 2) }, headers: @headers

        ActiveStorage::Blob.any_instance.stubs(:download).raises(
          ActiveRecord::StatementInvalid, "PG::UndefinedColumn: ERROR: column scribe_sessions.secret does not exist"
        )
        post "/api/v2/scribe_sessions/#{session_id}/commit", headers: @headers

        session = ScribeSession.find(session_id)
        assert_equal "failed", session.status
        assert_equal "transcript extraction failed", session.error["message"]
        assert_equal [ "failure" ], session.scribe_outputs.map(&:status).uniq

        get "/api/v2/scribe_sessions/#{session_id}", headers: @headers
        assert_no_match(/PG::|UndefinedColumn|secret/, response.body)
        assert_equal 0, UsageEvent.where(scribe_session_id: session_id).count
      end

      test "modality cross-uploads 409 both ways" do
        doc_session = create_document_session
        post "/api/v2/scribe_sessions/#{doc_session}/audio",
             params: { audio: audio_upload }, headers: @headers
        assert_response :conflict

        post "/api/v2/scribe_sessions",
             params: { modality: "audio", outputs: [ { type: "transcript" } ] }.to_json,
             headers: @headers.merge("Content-Type" => "application/json")
        audio_session = JSON.parse(response.body)["id"]
        post "/api/v2/scribe_sessions/#{audio_session}/documents",
             params: { document: image_upload }, headers: @headers
        assert_response :conflict
      end

      test "a session with no declared modality is determined by whichever upload reaches it first" do
        post "/api/v2/scribe_sessions", params: { outputs: [ { type: "transcript" } ] }.to_json,
             headers: @headers.merge("Content-Type" => "application/json")
        session_id = JSON.parse(response.body)["id"]
        assert_equal "pending", ScribeSession.find(session_id).modality

        post "/api/v2/scribe_sessions/#{session_id}/documents",
             params: { document: image_upload }, headers: @headers
        assert_response :ok
        assert_equal "document", ScribeSession.find(session_id).modality

        # Locked in now - a second, different-surface upload still 409s.
        post "/api/v2/scribe_sessions/#{session_id}/audio",
             params: { audio: audio_upload }, headers: @headers
        assert_response :conflict
      end

      test "committing a document session with no documents is a 422" do
        session_id = create_document_session
        post "/api/v2/scribe_sessions/#{session_id}/commit", headers: @headers
        assert_response :unprocessable_entity
        assert_equal "document_upload_failed", JSON.parse(response.body).dig("error", "code")
      end

      # ── upload hardening ─────────────────────────────────────────────────

      # /Count is written by whoever made the file. Trusting it let a 40-page
      # report declare itself as 1, slipping under MAX_DOCUMENT_PAGES and under
      # the per-page credit hold while still costing 40 pages of vision tokens.
      test "a PDF understating its own page count is counted by walking the page tree" do
        session_id = create_document_session
        post "/api/v2/scribe_sessions/#{session_id}/documents",
             params: { document: pdf_upload(pages: 3, declared: 1) }, headers: @headers
        assert_response :ok
        assert_equal 3, JSON.parse(response.body)["pages"]
      end

      # A 300-byte file declaring a four-billion-entry xref subsection used to
      # spin a Puma thread for hours; three of them took the whole pool down.
      # The assertion that matters is that the request RETURNS, quickly.
      test "a PDF declaring an enormous xref table cannot hang the request" do
        session_id = create_document_session
        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        post "/api/v2/scribe_sessions/#{session_id}/documents",
             params: { document: xref_bomb_upload }, headers: @headers
        elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

        assert_response :unprocessable_entity
        assert_operator elapsed, :<,
                        Api::V2::ScribeSessionsController::PDF_PARSE_TIMEOUT_SECONDS + 5,
                        "hostile PDF parsing was not bounded"
      end

      # pdf-reader walks /Kids with no cycle guard, so a page tree that lists
      # itself as its own kid recurses until the stack blows. SystemStackError is
      # NOT a StandardError, so a bare `rescue StandardError` misses it and the
      # walk 500s on a public endpoint — a regression the page-tree fix
      # introduced, since the old declared-/Count read returned a clean 200.
      test "a PDF whose page tree contains a cycle is a 422, not a 500" do
        session_id = create_document_session
        post "/api/v2/scribe_sessions/#{session_id}/documents",
             params: { document: cyclic_pdf_upload }, headers: @headers

        assert_response :unprocessable_entity
        assert_equal "validation_error", JSON.parse(response.body).dig("error", "code")
      end

      # The wall-clock bound does not bound allocation: PDF::Reader.new inflates
      # a compressed xref stream in its constructor with no output cap, and a
      # 4 KB nested-FlateDecode stream decodes to gigabytes in well under the
      # 2 s timeout — the process was OOM-killed before the timer fired. The
      # inflate is capped (config/initializers/pdf_reader_inflate_cap.rb), so
      # this must be a quick 422 that never allocated more than the cap.
      test "a PDF whose xref stream is a decompression bomb is a 422 without inflating it" do
        session_id = create_document_session
        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        post "/api/v2/scribe_sessions/#{session_id}/documents",
             params: { document: flate_bomb_pdf_upload }, headers: @headers
        elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

        assert_response :unprocessable_entity
        assert_equal "validation_error", JSON.parse(response.body).dig("error", "code")
        assert_operator elapsed, :<, 5, "the bomb was inflated rather than refused"
      end

      test "the page cap is enforced across separate uploads, not just per file" do
        # Derived from the cap so this keeps testing the boundary if it moves:
        # each file is under the cap on its own, and together they are over it.
        first = ScribeSession::MAX_DOCUMENT_PAGES - 5
        second = 6

        session_id = create_document_session
        post "/api/v2/scribe_sessions/#{session_id}/documents",
             params: { document: pdf_upload(pages: first) }, headers: @headers
        assert_response :ok
        assert_equal first, JSON.parse(response.body)["pages"]

        post "/api/v2/scribe_sessions/#{session_id}/documents",
             params: { document: pdf_upload(pages: second) }, headers: @headers
        assert_response :unprocessable_entity
        assert_equal "document_upload_failed", JSON.parse(response.body).dig("error", "code")
        assert_equal first, ScribeSession.find(session_id).document_pages, "a rejected upload must not increment"
      end

      # ── completeness + billing ───────────────────────────────────────────

      # The failure that used to be invisible: a 200 whose finish_reason says the
      # model ran out of budget mid-report. The extracted half must NOT become
      # the transcript, and the session must not read as completed.
      test "a truncated extraction fails the session instead of persisting half a report" do
        stub_request(:post, CHAT_URL).to_return(
          status: 200, headers: { "Content-Type" => "application/json" },
          body: { choices: [ { message: { content: "Hemoglobin | 13.5" }, finish_reason: "length" } ],
                  usage: { prompt_tokens: 900, completion_tokens: 4096 } }.to_json
        )

        session_id = create_document_session
        post "/api/v2/scribe_sessions/#{session_id}/documents",
             params: { document: pdf_upload(pages: 12) }, headers: @headers
        post "/api/v2/scribe_sessions/#{session_id}/commit", headers: @headers

        session = ScribeSession.find(session_id)
        assert_equal "failed", session.status
        assert_nil session.transcript
      end

      # The provider counted those tokens whether or not we could use them, so
      # the attempt is recorded — as :failed, and without deducting credits,
      # because the customer is not charged for a run that produced nothing.
      test "a billed-but-unusable OCR attempt is recorded as a failed usage event" do
        stub_request(:post, CHAT_URL).to_return(
          status: 200, headers: { "Content-Type" => "application/json" },
          body: { choices: [ { message: { content: "partial" }, finish_reason: "length" } ],
                  usage: { prompt_tokens: 900, completion_tokens: 4096 } }.to_json
        )

        session_id = create_document_session
        post "/api/v2/scribe_sessions/#{session_id}/documents",
             params: { document: pdf_upload(pages: 12) }, headers: @headers
        post "/api/v2/scribe_sessions/#{session_id}/commit", headers: @headers

        event = UsageEvent.find_by(scribe_session_id: session_id, function: "ocr")
        assert event, "the billed attempt was absorbed silently"
        assert_equal "failed", event.status
        assert_equal 900, event.input_tokens
        assert_equal 4096, event.output_tokens
        # The adapter's usage carries no page count — only the success path
        # grafts one on — so without help this prices the per-page component at
        # zero and hides the quantity the commit hold was sized on.
        assert_equal 12, event.pages
      end

      # A truncated primary that falls back is TWO physical attempts, and the
      # provider billed both. Llm::Caller used to drop the primary's error on
      # the floor, so its tokens were recorded nowhere at all.
      test "an attempt abandoned for the fallback provider is still metered" do
        model = create(:ai_model, api_model_id: "gpt-4o-mini")
        fallback = create(:ai_model, api_model_id: "claude-3-5-sonnet-latest",
                                     ai_provider: create(:ai_provider, kind: "anthropic",
                                                                       base_url: "https://api.anthropic.com"))
        create(:model_assignment, scope_type: "System", scope_id: nil, function: "ocr",
                                  ai_model: model, fallback_ai_model: fallback)

        # Primary: billed, truncated, unusable. Fallback: the full extraction.
        stub_request(:post, CHAT_URL).to_return(
          status: 200, headers: { "Content-Type" => "application/json" },
          body: { choices: [ { message: { content: "partial" }, finish_reason: "length" } ],
                  usage: { prompt_tokens: 900, completion_tokens: 4096 } }.to_json
        )
        stub_request(:post, "https://api.anthropic.com/v1/messages").to_return(
          status: 200, headers: { "Content-Type" => "application/json" },
          body: { id: "m", type: "message", role: "assistant", stop_reason: "end_turn",
                  content: [ { type: "text", text: "Hemoglobin | 13.5 g/dL" } ],
                  usage: { input_tokens: 800, output_tokens: 250 } }.to_json
        )

        session_id = create_document_session
        post "/api/v2/scribe_sessions/#{session_id}/documents",
             params: { document: pdf_upload(pages: 2) }, headers: @headers
        post "/api/v2/scribe_sessions/#{session_id}/commit", headers: @headers

        session = ScribeSession.find(session_id)
        assert_includes session.transcript.text, "Hemoglobin"

        events = UsageEvent.where(scribe_session_id: session_id, function: "ocr").order(:id)
        assert_equal 2, events.count, "the abandoned primary attempt was billed to nobody"
        assert_equal %w[failed finalized], events.map(&:status)
        assert_equal 4096, events.first.output_tokens
      end

      # The primary was billed (truncated 200) and the fallback then failed
      # outright. The session fails, but the primary's spend must still reach the
      # ledger: Llm::Caller used to let the fallback's exception escape with the
      # primary error dropped on the floor.
      test "a billed primary attempt is metered even when the fallback also fails" do
        model = create(:ai_model, api_model_id: "gpt-4o-mini")
        fallback = create(:ai_model, api_model_id: "claude-3-5-sonnet-latest",
                                     ai_provider: create(:ai_provider, kind: "anthropic",
                                                                       base_url: "https://api.anthropic.com"))
        create(:model_assignment, scope_type: "System", scope_id: nil, function: "ocr",
                                  ai_model: model, fallback_ai_model: fallback)

        stub_request(:post, CHAT_URL).to_return(
          status: 200, headers: { "Content-Type" => "application/json" },
          body: { choices: [ { message: { content: "partial" }, finish_reason: "length" } ],
                  usage: { prompt_tokens: 900, completion_tokens: 4096 } }.to_json
        )
        # Fallback: a transport failure — billed nothing, records nothing.
        stub_request(:post, "https://api.anthropic.com/v1/messages").to_return(status: 502, body: "bad gateway")

        session_id = create_document_session
        post "/api/v2/scribe_sessions/#{session_id}/documents",
             params: { document: pdf_upload(pages: 2) }, headers: @headers
        post "/api/v2/scribe_sessions/#{session_id}/commit", headers: @headers

        assert_equal "failed", ScribeSession.find(session_id).status
        events = UsageEvent.where(scribe_session_id: session_id, function: "ocr").order(:id)
        assert_equal 1, events.count, "the billed primary attempt was dropped when the fallback failed"
        assert_equal "failed", events.first.status
        assert_equal 4096, events.first.output_tokens
        assert_equal 2, events.first.pages
      end

      # Both providers billed us and neither produced a usable report: two
      # physical attempts, two failed rows, in the order they happened.
      test "two billed-but-unusable attempts are both metered, in order" do
        model = create(:ai_model, api_model_id: "gpt-4o-mini")
        fallback = create(:ai_model, api_model_id: "claude-3-5-sonnet-latest",
                                     ai_provider: create(:ai_provider, kind: "anthropic",
                                                                       base_url: "https://api.anthropic.com"))
        create(:model_assignment, scope_type: "System", scope_id: nil, function: "ocr",
                                  ai_model: model, fallback_ai_model: fallback)

        stub_request(:post, CHAT_URL).to_return(
          status: 200, headers: { "Content-Type" => "application/json" },
          body: { choices: [ { message: { content: "partial" }, finish_reason: "length" } ],
                  usage: { prompt_tokens: 900, completion_tokens: 4096 } }.to_json
        )
        stub_request(:post, "https://api.anthropic.com/v1/messages").to_return(
          status: 200, headers: { "Content-Type" => "application/json" },
          body: { id: "m", type: "message", role: "assistant", stop_reason: "max_tokens",
                  content: [ { type: "text", text: "also partial" } ],
                  usage: { input_tokens: 800, output_tokens: 3000 } }.to_json
        )

        session_id = create_document_session
        post "/api/v2/scribe_sessions/#{session_id}/documents",
             params: { document: pdf_upload(pages: 2) }, headers: @headers
        post "/api/v2/scribe_sessions/#{session_id}/commit", headers: @headers

        assert_equal "failed", ScribeSession.find(session_id).status
        events = UsageEvent.where(scribe_session_id: session_id, function: "ocr").order(:id)
        assert_equal 2, events.count
        assert_equal %w[failed failed], events.map(&:status)
        assert_equal [ 4096, 3000 ], events.map(&:output_tokens), "primary first, then fallback"
        assert_equal [ "#{session_id}:ocr:0", "#{session_id}:ocr:1" ], events.map(&:dedupe_key)
      end

      # A transport failure returned no tokens, so there is nothing to record —
      # recording a zero-cost row would just be noise in the ledger.
      test "a transport failure records no usage event" do
        stub_request(:post, CHAT_URL).to_return(status: 500, body: "boom")

        session_id = create_document_session
        post "/api/v2/scribe_sessions/#{session_id}/documents",
             params: { document: pdf_upload(pages: 2) }, headers: @headers
        post "/api/v2/scribe_sessions/#{session_id}/commit", headers: @headers

        assert_equal "failed", ScribeSession.find(session_id).status
        assert_equal 0, UsageEvent.where(scribe_session_id: session_id, function: "ocr").count
      end

      # Re-commit after a failed extraction runs OCR again — a second provider
      # call, a second charge — so it must not collide with the first attempt's
      # dedupe key and vanish.
      test "re-committing after a failed extraction meters the second attempt separately" do
        stub_request(:post, CHAT_URL).to_return(
          # Attempt one: billed, truncated, unusable.
          { status: 200, headers: { "Content-Type" => "application/json" },
            body: { choices: [ { message: { content: "partial" }, finish_reason: "length" } ],
                    usage: { prompt_tokens: 900, completion_tokens: 4096 } }.to_json },
          # Attempt two: the full extraction, then structuring.
          { status: 200, headers: { "Content-Type" => "application/json" },
            body: { choices: [ { message: { content: "Hemoglobin | 13.5 g/dL" }, finish_reason: "stop" } ],
                    usage: { prompt_tokens: 900, completion_tokens: 300 } }.to_json },
          { status: 200, headers: { "Content-Type" => "application/json" },
            body: { choices: [ { message: { content: {}.to_json }, finish_reason: "stop" } ],
                    usage: { prompt_tokens: 100, completion_tokens: 10 } }.to_json }
        )

        session_id = create_document_session
        post "/api/v2/scribe_sessions/#{session_id}/documents",
             params: { document: pdf_upload(pages: 2) }, headers: @headers
        post "/api/v2/scribe_sessions/#{session_id}/commit", headers: @headers
        assert_equal "failed", ScribeSession.find(session_id).status

        post "/api/v2/scribe_sessions/#{session_id}/commit", headers: @headers
        session = ScribeSession.find(session_id)
        assert_equal "completed", session.status
        assert_includes session.transcript.text, "Hemoglobin"

        events = UsageEvent.where(scribe_session_id: session_id, function: "ocr").order(:id)
        assert_equal 2, events.count, "the retried OCR call was billed to nobody"
        assert_equal %w[failed finalized], events.map(&:status)
      end

      private

      def create_document_session
        post "/api/v2/scribe_sessions",
             params: { modality: "document", outputs: [ { type: "transcript" } ] }.to_json,
             headers: @headers.merge("Content-Type" => "application/json")
        JSON.parse(response.body)["id"]
      end

      def pdf_upload(pages: 1, declared: nil)
        file = Tempfile.new([ "report", ".pdf" ])
        file.binmode
        file.write(minimal_pdf(pages: pages, declared: declared))
        file.rewind
        Rack::Test::UploadedFile.new(file.path, "application/pdf")
      end

      # Tiny, structurally plausible, and claims an xref subsection with four
      # billion entries. pdf-reader loops that count verbatim.
      def xref_bomb_upload
        header = "%PDF-1.4\n"
        body = "1 0 obj\n<< /Type /Catalog /Pages 2 0 R >>\nendobj\n" \
               "2 0 obj\n<< /Type /Pages /Kids [3 0 R] /Count 1 >>\nendobj\n" \
               "3 0 obj\n<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] >>\nendobj\n"
        xref_pos = header.bytesize + body.bytesize
        xref = "xref\n0 4000000000\n0000000000 65535 f \n"
        trailer = "trailer\n<< /Size 4000000000 /Root 1 0 R >>\nstartxref\n#{xref_pos}\n%%EOF\n"

        file = Tempfile.new([ "bomb", ".pdf" ])
        file.binmode
        file.write(header + body + xref + trailer)
        file.rewind
        Rack::Test::UploadedFile.new(file.path, "application/pdf")
      end

      # Tiny: the /Pages node lists itself as its own kid, so a page-tree walk
      # with no cycle guard recurses until the stack overflows.
      #
      # The xref offsets are computed from the object strings, never hand-counted:
      # an offset that lands even one byte inside "2 0 obj" makes pdf-reader
      # raise MalformedPDFError (a StandardError) BEFORE it ever walks the tree,
      # and this test then passes for the wrong reason — the SystemStackError
      # rescue it exists to guard would go unexercised.
      def cyclic_pdf_upload
        header = "%PDF-1.4\n"
        objects = [
          "1 0 obj\n<< /Type /Catalog /Pages 2 0 R >>\nendobj\n",
          "2 0 obj\n<< /Type /Pages /Kids [2 0 R] /Count 1 >>\nendobj\n"
        ]
        body = +""
        offsets = []
        objects.each do |obj|
          offsets << (header.bytesize + body.bytesize)
          body << obj
        end
        xref_pos = header.bytesize + body.bytesize
        xref = +"xref\n0 3\n0000000000 65535 f \n"
        offsets.each { |o| xref << format("%010d 00000 n \n", o) }
        trailer = "trailer\n<< /Size 3 /Root 1 0 R >>\nstartxref\n#{xref_pos}\n%%EOF\n"

        file = Tempfile.new([ "cyclic", ".pdf" ])
        file.binmode
        file.write(header + body + xref + trailer)
        file.rewind
        Rack::Test::UploadedFile.new(file.path, "application/pdf")
      end

      # A PDF 1.5 file whose cross-reference table is a compressed `/Type /XRef`
      # stream — which PDF::Reader.new decodes eagerly, before anything is
      # asked of it — and whose stream data is a nested FlateDecode bomb: zeros
      # deflated twice, so a few hundred bytes on disk decode to ~64 MB per
      # layer. Everything else in the file is a valid one-page document.
      def flate_bomb_pdf_upload
        header = "%PDF-1.5\n"
        objects = [
          "1 0 obj\n<< /Type /Catalog /Pages 2 0 R >>\nendobj\n",
          "2 0 obj\n<< /Type /Pages /Kids [3 0 R] /Count 1 >>\nendobj\n",
          "3 0 obj\n<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] >>\nendobj\n"
        ]
        body = objects.join
        payload = Zlib::Deflate.deflate(Zlib::Deflate.deflate("\0" * 64.megabytes))
        xref_offset = header.bytesize + body.bytesize
        xref_stream = "4 0 obj\n<< /Type /XRef /Size 5 /W [1 4 2] /Root 1 0 R " \
                      "/Filter [/FlateDecode /FlateDecode] /Length #{payload.bytesize} >>\n" \
                      "stream\n#{payload}\nendstream\nendobj\n"
        trailer = "startxref\n#{xref_offset}\n%%EOF\n"

        file = Tempfile.new([ "bomb", ".pdf" ])
        file.binmode
        file.write(header + body + xref_stream + trailer)
        file.rewind
        assert_operator file.size, :<, 100.kilobytes, "the bomb is meant to be tiny on disk"
        Rack::Test::UploadedFile.new(file.path, "application/pdf")
      end

      def broken_pdf_upload
        file = Tempfile.new([ "broken", ".pdf" ])
        file.binmode
        file.write("%PDF-1.4 this is not a real pdf")
        file.rewind
        Rack::Test::UploadedFile.new(file.path, "application/pdf")
      end

      def image_upload
        file = Tempfile.new([ "scan", ".png" ])
        file.binmode
        # Any bytes work: images are validated by declared content type here.
        file.write("\x89PNG\r\n\x1a\nfakebytes")
        file.rewind
        Rack::Test::UploadedFile.new(file.path, "image/png")
      end

      def audio_upload
        file = Tempfile.new([ "a", ".webm" ])
        file.binmode
        file.write("audio-bytes")
        file.rewind
        Rack::Test::UploadedFile.new(file.path, "audio/webm")
      end
    end
  end
end
