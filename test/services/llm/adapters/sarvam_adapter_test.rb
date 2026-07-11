require "test_helper"

# Sarvam STT adapter against stubbed HTTP (WebMock). Rails-integrated so
# faraday-multipart's :multipart middleware is registered.
class SarvamAdapterTest < ActiveSupport::TestCase
  ENDPOINT = "https://api.sarvam.ai/speech-to-text".freeze

  def config(model: "saaras:v3", options: {}, fallback: nil)
    Llm::Config.new(
      provider_kind: :sarvam, provider_name: "Sarvam", api_model_id: model,
      base_url: "https://api.sarvam.ai", api_key: "sk_test_sarvam",
      capabilities: { accepts_audio: true, can_transcribe: true },
      options: options, fallback: fallback
    )
  end

  def adapter(cfg = config)
    Llm::Adapters::Sarvam.new(cfg)
  end

  def audio
    file = Tempfile.new([ "seg", ".webm" ])
    file.binmode
    file.write("opus-bytes")
    file.rewind
    file
  end

  def stub_ok(transcript: "രോഗിക്ക് പനി ഉണ്ട്", language: "ml-IN")
    stub_request(:post, ENDPOINT).to_return(
      status: 200, headers: { "Content-Type" => "application/json" },
      body: { request_id: "req_1", transcript: transcript, language_code: language }.to_json
    )
  end

  # Extract a simple multipart field value from a raw WebMock request body.
  def field(body, name)
    body[/name="#{name}"\r?\n\r?\n(.*?)\r?\n--/m, 1]
  end

  test "transcribe mode posts /speech-to-text with mode=transcribe and the auth header" do
    stub_ok
    result = adapter.transcribe(audio, language: "ml", mode: :transcribe, audio_seconds: 3)

    assert_equal "രോഗിക്ക് പനി ഉണ്ട്", result.text
    assert_equal "ml-IN", result.language
    assert_equal "saaras:v3", result.model
    assert_equal "Sarvam", result.provider
    assert_equal 3.0, result.usage.audio_seconds

    assert_requested(:post, ENDPOINT) do |req|
      req.headers["Api-Subscription-Key"] == "sk_test_sarvam" &&
        field(req.body, "model") == "saaras:v3" &&
        field(req.body, "mode") == "transcribe" &&
        field(req.body, "language_code") == "ml-IN"
    end
  end

  test "translate mode maps to Sarvam mode=translate (Indic audio -> English)" do
    stub_ok(transcript: "The patient has a fever", language: "en-IN")
    result = adapter.transcribe(audio, language: "ml", mode: :translate, audio_seconds: 3)

    assert_equal "The patient has a fever", result.text
    assert_requested(:post, ENDPOINT) { |req| field(req.body, "mode") == "translate" }
  end

  test "options[:sarvam_mode] overrides with a Sarvam-only mode (codemix)" do
    stub_ok
    adapter(config(options: { sarvam_mode: "codemix" })).transcribe(audio, language: "ml", mode: :transcribe)

    assert_requested(:post, ENDPOINT) { |req| field(req.body, "mode") == "codemix" }
  end

  test "a blank language auto-detects (language_code=unknown)" do
    stub_ok
    adapter.transcribe(audio, language: nil, mode: :transcribe)

    assert_requested(:post, ENDPOINT) { |req| field(req.body, "language_code") == "unknown" }
  end

  test "a 4xx (e.g. audio over the 30s REST cap) maps to BadResponse so Caller falls back" do
    stub_request(:post, ENDPOINT).to_return(
      status: 400, headers: { "Content-Type" => "application/json" },
      body: { error: { message: "audio too long" } }.to_json
    )
    assert_raises(Llm::BadResponse) { adapter.transcribe(audio, mode: :transcribe) }
  end

  test "a 429 maps to RateLimited" do
    stub_request(:post, ENDPOINT).to_return(status: 429, body: "slow down")
    assert_raises(Llm::RateLimited) { adapter.transcribe(audio, mode: :transcribe) }
  end
end
