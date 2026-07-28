require "test_helper"

module Api
  module V2
    # OCR modality end-to-end: create a document session, upload a lab report
    # (PDF/image), commit, poll. OCR runs once (vision LLM -> Transcript),
    # structuring consumes the extracted text through the unchanged output
    # loop, and metering records one :ocr event (with pages) plus one
    # :structuring event per output.
    class DocumentsTest < ActionDispatch::IntegrationTest
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

      test "modality cross-uploads 409 both ways" do
        doc_session = create_document_session
        post "/api/v2/scribe_sessions/#{doc_session}/audio",
             params: { audio: audio_upload }, headers: @headers
        assert_response :conflict

        post "/api/v2/scribe_sessions", params: { outputs: [ { type: "transcript" } ] }.to_json,
             headers: @headers.merge("Content-Type" => "application/json")
        audio_session = JSON.parse(response.body)["id"]
        post "/api/v2/scribe_sessions/#{audio_session}/documents",
             params: { document: image_upload }, headers: @headers
        assert_response :conflict
      end

      test "committing a document session with no documents is a 422" do
        session_id = create_document_session
        post "/api/v2/scribe_sessions/#{session_id}/commit", headers: @headers
        assert_response :unprocessable_entity
        assert_equal "document_upload_failed", JSON.parse(response.body).dig("error", "code")
      end

      private

      def create_document_session
        post "/api/v2/scribe_sessions",
             params: { modality: "document", outputs: [ { type: "transcript" } ] }.to_json,
             headers: @headers.merge("Content-Type" => "application/json")
        JSON.parse(response.body)["id"]
      end

      # A structurally valid multi-page PDF built with correct xref offsets so
      # pdf-reader parses it.
      def minimal_pdf(pages: 1)
        kids = (0...pages).map { |i| "#{3 + i} 0 R" }.join(" ")
        objects = []
        objects << "1 0 obj\n<< /Type /Catalog /Pages 2 0 R >>\nendobj\n"
        objects << "2 0 obj\n<< /Type /Pages /Kids [#{kids}] /Count #{pages} >>\nendobj\n"
        pages.times do |i|
          objects << "#{3 + i} 0 obj\n<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] >>\nendobj\n"
        end

        header = "%PDF-1.4\n"
        body = +""
        offsets = []
        objects.each do |obj|
          offsets << (header.bytesize + body.bytesize)
          body << obj
        end
        xref_pos = header.bytesize + body.bytesize
        xref = +"xref\n0 #{objects.size + 1}\n0000000000 65535 f \n"
        offsets.each { |offset| xref << format("%010d 00000 n \n", offset) }
        trailer = "trailer\n<< /Size #{objects.size + 1} /Root 1 0 R >>\nstartxref\n#{xref_pos}\n%%EOF\n"
        header + body + xref + trailer
      end

      def pdf_upload(pages: 1)
        file = Tempfile.new([ "report", ".pdf" ])
        file.binmode
        file.write(minimal_pdf(pages: pages))
        file.rewind
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
