require "test_helper"
require "mocha/minitest"

# Azure Foundry (LLM Speech API / MAI-Transcribe) adapter against stubbed HTTP
# (WebMock). Rails-integrated so faraday-multipart's :multipart middleware is
# registered.
class AzureFoundryAdapterTest < ActiveSupport::TestCase
  ENDPOINT = "https://acme.cognitiveservices.azure.com/speechtotext/transcriptions:transcribe".freeze
  URL = "#{ENDPOINT}?api-version=2025-10-15".freeze

  def config(model: "mai-transcribe-1.5", options: {}, fallback: nil)
    Llm::Config.new(
      provider_kind: :azure_foundry, provider_name: "Azure Foundry", api_model_id: model,
      base_url: "https://acme.cognitiveservices.azure.com", api_key: "az_test_key",
      capabilities: { accepts_audio: true, can_transcribe: true },
      options: options, fallback: fallback
    )
  end

  def adapter(cfg = config)
    Llm::Adapters::AzureFoundry.new(cfg)
  end

  def audio
    file = Tempfile.new([ "seg", ".webm" ])
    file.binmode
    file.write("opus-bytes")
    file.rewind
    file
  end

  def stub_ok(text: "രോഗിക്ക് പനി ഉണ്ട്", locale: "ml", duration_ms: 3050, url: URL)
    stub_request(:post, url).to_return(
      status: 200, headers: { "Content-Type" => "application/json" },
      body: {
        durationMilliseconds: duration_ms,
        combinedPhrases: [ { channel: 0, text: text } ],
        phrases: [
          { offsetMilliseconds: 80, durationMilliseconds: duration_ms, text: text,
            locale: locale, confidence: 0.93 }
        ]
      }.to_json
    )
  end

  # The parsed JSON `definition` multipart part from a raw WebMock request body.
  def definition(body)
    JSON.parse(body[/name="definition"\r?\n\r?\n(.*?)\r?\n--/m, 1])
  end

  test "posts multipart audio + definition with the subscription key and the MAI model in enhanced mode" do
    stub_ok
    result = adapter.transcribe(audio, language: nil, mode: :transcribe, audio_seconds: 3)

    assert_equal "രോഗിക്ക് പനി ഉണ്ട്", result.text
    assert_equal "ml", result.language
    assert_equal "mai-transcribe-1.5", result.model
    assert_equal "Azure Foundry", result.provider
    assert_equal 3.0, result.usage.audio_seconds

    assert_requested(:post, URL) do |req|
      dfn = definition(req.body)
      req.headers["Ocp-Apim-Subscription-Key"] == "az_test_key" &&
        dfn["enhancedMode"] == { "enabled" => true, "model" => "mai-transcribe-1.5", "task" => "transcribe" } &&
        !dfn.key?("locales") &&
        req.body.include?('name="audio"; filename="seg')
    end
  end

  test "a language hint forces single-locale recognition using the bare ISO code" do
    stub_ok
    adapter.transcribe(audio, language: "ml-IN", mode: :transcribe)

    assert_requested(:post, URL) { |req| definition(req.body)["locales"] == [ "ml" ] }
  end

  test "the portable 'auto' hint keeps the default multilingual mode (no locales)" do
    stub_ok
    adapter.transcribe(audio, language: "auto", mode: :transcribe)

    assert_requested(:post, URL) { |req| !definition(req.body).key?("locales") }
  end

  test "translate mode requests task=translate targeting English" do
    stub_ok(text: "The patient has a fever", locale: "en")
    result = adapter.transcribe(audio, language: "ml", mode: :translate, audio_seconds: 3)

    assert_equal "The patient has a fever", result.text
    assert_requested(:post, URL) do |req|
      mode = definition(req.body)["enhancedMode"]
      mode["task"] == "translate" && mode["targetLanguage"] == "en"
    end
  end

  test "options phrase_list and transcribe_style feed entity biasing and output style" do
    stub_ok
    cfg = config(options: { phrase_list: [ "Dolo 650", "Metformin" ], transcribe_style: "verbatim" })
    adapter(cfg).transcribe(audio, language: "en", mode: :transcribe)

    assert_requested(:post, URL) do |req|
      dfn = definition(req.body)
      dfn["phraseList"] == { "phrases" => [ "Dolo 650", "Metformin" ] } &&
        dfn["enhancedMode"]["transcribeStyle"] == "verbatim"
    end
  end

  test "usage falls back to the provider-reported duration when the caller has none" do
    stub_ok(duration_ms: 57_187)
    result = adapter.transcribe(audio, mode: :transcribe, audio_seconds: 0)

    assert_in_delta 57.187, result.usage.audio_seconds, 0.0001
  end

  test "options azure_api_version overrides the pinned preview api-version" do
    url = "#{ENDPOINT}?api-version=2026-06-01"
    stub_ok(url: url)
    adapter(config(options: { azure_api_version: "2026-06-01" })).transcribe(audio, mode: :transcribe)

    assert_requested(:post, url)
  end

  test "a 200 whose combinedPhrases is not an array maps to BadResponse" do
    stub_request(:post, URL).to_return(
      status: 200, headers: { "Content-Type" => "application/json" },
      body: { combinedPhrases: "hello world" }.to_json
    )
    assert_raises(Llm::BadResponse) { adapter.transcribe(audio, mode: :transcribe) }
  end

  test "an empty combinedPhrases is a silent segment, not an error" do
    stub_request(:post, URL).to_return(
      status: 200, headers: { "Content-Type" => "application/json" },
      body: { durationMilliseconds: 900, combinedPhrases: [], phrases: [] }.to_json
    )
    result = adapter.transcribe(audio, mode: :transcribe)

    assert_equal "", result.text
    assert_nil result.language
  end

  test "a malformed phrases field yields nil language, not a TypeError" do
    stub_request(:post, URL).to_return(
      status: 200, headers: { "Content-Type" => "application/json" },
      body: { combinedPhrases: [ { text: "ok" } ], phrases: "corrupt" }.to_json
    )
    result = adapter.transcribe(audio, mode: :transcribe)

    assert_equal "ok", result.text
    assert_nil result.language
  end

  test "junk elements inside combinedPhrases are skipped, not crashed on" do
    stub_request(:post, URL).to_return(
      status: 200, headers: { "Content-Type" => "application/json" },
      body: { combinedPhrases: [ { text: "ok" }, 123, nil ], phrases: [] }.to_json
    )
    result = adapter.transcribe(audio, mode: :transcribe)

    assert_equal "ok", result.text
  end

  test "a non-JSON 200 maps to BadResponse so Caller falls back" do
    stub_request(:post, URL).to_return(
      status: 200, headers: { "Content-Type" => "text/html" }, body: "<html>gateway</html>"
    )
    assert_raises(Llm::BadResponse) { adapter.transcribe(audio, mode: :transcribe) }
  end

  test "a JSON 200 without combinedPhrases maps to BadResponse" do
    stub_request(:post, URL).to_return(
      status: 200, headers: { "Content-Type" => "application/json" },
      body: { error: "unexpected shape" }.to_json
    )
    assert_raises(Llm::BadResponse) { adapter.transcribe(audio, mode: :transcribe) }
  end

  test "a 4xx maps to BadResponse carrying the provider's error detail" do
    stub_request(:post, URL).to_return(
      status: 400, headers: { "Content-Type" => "application/json" },
      body: { error: { code: "invalid_audio", message: "unsupported audio" } }.to_json
    )
    error = assert_raises(Llm::BadResponse) { adapter.transcribe(audio, mode: :transcribe) }
    assert_match(/status 400/, error.message)
    assert_match(/invalid_audio/, error.message)
  end

  test "a 429 maps to RateLimited" do
    stub_request(:post, URL).to_return(status: 429, body: "slow down")
    assert_raises(Llm::RateLimited) { adapter.transcribe(audio, mode: :transcribe) }
  end

  test "webm auto-remuxes to ogg before the request when ffmpeg is available" do
    stub_ok
    ogg = Tempfile.new([ "converted", ".ogg" ])
    ogg.binmode
    ogg.write("OggS-fake-bytes")
    ogg.rewind

    Llm::AudioConverter.stubs(:to_ogg).returns(ogg)
    adapter.transcribe(audio, mode: :transcribe)

    assert_requested(:post, URL) do |req|
      req.body.include?("Content-Type: audio/ogg") && !req.body.include?("audio/webm")
    end
    assert ogg.closed?, "adapter must close the converted tempfile"
  end

  test "webm goes as-is when no converter is available (fallback still drives recovery)" do
    stub_ok
    Llm::AudioConverter.stubs(:to_ogg).returns(nil)
    adapter.transcribe(audio, mode: :transcribe)

    assert_requested(:post, URL) { |req| req.body.include?("Content-Type: audio/webm") }
  end

  test "accepted formats are never run through the converter" do
    stub_ok
    wav = Tempfile.new([ "seg", ".wav" ])
    wav.binmode
    wav.write("RIFF-bytes")
    wav.rewind

    Llm::AudioConverter.expects(:to_ogg).never
    adapter.transcribe(wav, mode: :transcribe)

    assert_requested(:post, URL) { |req| req.body.include?("Content-Type: audio/wav") }
  end

  test "the model id flows from config, so new Foundry speech models are a data change" do
    stub_ok
    result = adapter(config(model: "mai-transcribe-2")).transcribe(audio, mode: :transcribe)

    assert_equal "mai-transcribe-2", result.model
    assert_requested(:post, URL) { |req| definition(req.body)["enhancedMode"]["model"] == "mai-transcribe-2" }
  end

  test "the registry resolves the azure_foundry provider kind" do
    assert_instance_of Llm::Adapters::AzureFoundry, Llm::Registry.adapter_for(config)
  end
end
