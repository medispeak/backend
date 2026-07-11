require "test_helper"

# The Caller's fallback retry re-sends the SAME audio IO the failed primary
# attempt already read to EOF. Without a rewind, the fallback posts a 0-byte
# file — silently, as an empty transcript. The canonical trigger: Sarvam's REST
# endpoint rejecting >30s audio AFTER reading it, then the Whisper fallback
# uploading nothing.
class CallerFallbackTest < ActiveSupport::TestCase
  SARVAM_URL = "https://api.sarvam.ai/speech-to-text".freeze
  OPENAI_URL = "https://api.openai.com/v1/audio/transcriptions".freeze

  def audio(content = "opus-bytes-full-recording")
    file = Tempfile.new([ "seg", ".webm" ])
    file.binmode
    file.write(content)
    file.rewind
    file
  end

  def sarvam_with_whisper_fallback
    whisper = Llm::Config.new(
      provider_kind: :openai_compatible, provider_name: "OpenAI",
      api_model_id: "whisper-1", base_url: "https://api.openai.com/",
      api_key: "sk-test", capabilities: { can_transcribe: true }
    )
    Llm::Config.new(
      provider_kind: :sarvam, provider_name: "Sarvam", api_model_id: "saaras:v3",
      base_url: "https://api.sarvam.ai", api_key: "sk_sarvam",
      capabilities: { can_transcribe: true }, fallback: whisper
    )
  end

  test "fallback after a consumed-IO failure re-uploads the FULL audio, not 0 bytes" do
    # Sarvam reads the multipart body, then rejects (the >30s case).
    stub_request(:post, SARVAM_URL).to_return(status: 400, body: { error: "audio too long" }.to_json)
    fallback_body = nil
    stub_request(:post, OPENAI_URL).with { |req| fallback_body = req.body; true }
      .to_return(
        status: 200, headers: { "Content-Type" => "application/json" },
        body: { text: "whole transcript" }.to_json
      )

    result = Llm::Caller.transcribe(sarvam_with_whisper_fallback, audio, mode: :transcribe, audio_seconds: 45)

    assert_equal "whole transcript", result.text
    assert_includes fallback_body.to_s, "opus-bytes-full-recording",
                    "the fallback upload must contain the audio bytes (IO must be rewound after the primary attempt consumed it)"
  end
end
