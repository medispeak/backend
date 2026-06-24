require "test_helper"

# Golden-contract test for the legacy v1 flow, now served by the model-agnostic
# engine. Locks the response shape so the OpenaiHelper refactor (and future
# model-config changes) don't silently break existing plugin clients.
class Api::V1::TranscriptionsGoldenTest < ActionDispatch::IntegrationTest
  setup do
    @token = create(:api_token)
    @account = @token.account
    @headers = { "Authorization" => "Bearer #{@token.raw_token}" }

    template = create(:template)
    @page = create(:page, template: template, prompt: "Fill the form")
    create(:form_field, page: @page, title: "complaint", friendly_name: "Complaint", field_type: "string")

    stub_request(:post, %r{https://api\.openai\.com/v1/audio/(transcriptions|translations)})
      .to_return(status: 200, headers: { "Content-Type" => "application/json" },
                 body: { text: "patient reports a headache" }.to_json)

    stub_request(:post, %r{https://api\.openai\.com/v1/chat/completions})
      .to_return(status: 200, headers: { "Content-Type" => "application/json" },
                 body: {
                   choices: [{ message: { content: { complaint: "headache" }.to_json }, finish_reason: "stop" }],
                   usage: { prompt_tokens: 11, completion_tokens: 3, total_tokens: 14 }
                 }.to_json)
  end

  test "create transcription returns transcribed text and status" do
    post "/api/v1/pages/#{@page.id}/transcriptions",
         params: { transcription: { audio_file: audio_upload, duration: 12 } },
         headers: @headers

    assert_response :created
    body = JSON.parse(response.body)
    assert_equal "transcribed", body["status"]
    assert_equal "patient reports a headache", body["transcription_text"]
    assert body.key?("id")
    assert body.key?("audio_file_url")
    assert_equal "Transcription #{body['id']}", body["title"]
  end

  test "generate_completion fills ai_response and records tokens" do
    post "/api/v1/pages/#{@page.id}/transcriptions",
         params: { transcription: { audio_file: audio_upload, duration: 12 } },
         headers: @headers
    id = JSON.parse(response.body)["id"]

    post "/api/v1/transcriptions/#{id}/generate_completion", headers: @headers

    assert_response :success
    body = JSON.parse(response.body)
    assert_equal "completion_generated", body["status"]
    assert_equal({ "complaint" => "headache" }, body["ai_response"])
    assert_equal 11, body["prompt_tokens"]
    assert_equal 3, body["completion_tokens"]
    assert_equal 14, body["total_tokens"]
  end

  test "unauthenticated request is rejected" do
    post "/api/v1/pages/#{@page.id}/transcriptions",
         params: { transcription: { audio_file: audio_upload } }
    assert_response :unauthorized
  end

  private

  def audio_upload
    file = Tempfile.new(["clip", ".mp3"])
    file.write("fake audio bytes")
    file.rewind
    Rack::Test::UploadedFile.new(file.path, "audio/mpeg")
  end
end
