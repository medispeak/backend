module Scribe
  # Mints a short-lived credential the BROWSER uses to connect DIRECTLY to the
  # realtime provider, so the account key never reaches the client.
  #
  # Today: OpenAI realtime transcription. The backend POSTs to
  # /v1/realtime/client_secrets with the account key and returns the ephemeral
  # token (valid ~10 min) plus the session config the browser echoes when it
  # opens its WebRTC connection. The realtime model is resolved through the same
  # ConfigResolver seam as ASR/structuring (function :realtime), defaulting to
  # gpt-4o-transcribe on OpenAI.
  class RealtimeToken
    Result = Struct.new(:provider, :token, :expires_at, :url, :model, :session, keyword_init: true)

    # Where the browser POSTs its WebRTC SDP offer (with the ephemeral token).
    OPENAI_CALLS_URL = "https://api.openai.com/v1/realtime/calls".freeze
    EXPIRES_SECONDS = 600

    def self.call(session)
      new(session).call
    end

    def initialize(session)
      @session = session
    end

    def call
      config = Llm::ConfigResolver.call(function: :realtime, account: @session.account)
      # Guard on the actual provider identity, not just the kind: OpenRouter and
      # other OpenAI-compatible providers share the kind but have a different
      # host and no realtime/client_secrets endpoint. Minting the OpenAI calls
      # URL (below) against them would hand the browser a token that can't
      # connect. Require an api.openai.com base.
      unless openai_host?(config.base_url)
        raise Llm::Error, "Realtime requires an OpenAI provider assignment (got #{config.provider_name || config.base_url})"
      end

      mint_openai(config)
    end

    private

    def mint_openai(config)
      body = { expires_after: { anchor: "created_at", seconds: EXPIRES_SECONDS }, session: session_config(config) }
      resp = connection(config).post("/v1/realtime/client_secrets", body).body

      Result.new(
        provider: "openai",
        token: extract_token(resp),
        expires_at: resp["expires_at"],
        url: OPENAI_CALLS_URL,
        model: config.api_model_id,
        session: body[:session]
      )
    rescue Faraday::Error => e
      raise Llm::BadResponse, "realtime token mint failed: #{e.message}"
    end

    # A TRANSCRIPTION session (type: "transcription", NOT "realtime"): PCM input,
    # the resolved transcribe model, and server VAD so partial transcripts
    # finalize on the speaker's pauses. type: "realtime" is a speech-to-speech
    # session that requires a top-level realtime model — OpenAI rejected our
    # mint with missing_model. A transcription session carries no top-level
    # model; the model lives under audio.input.transcription. A language hint is
    # forwarded when the session carries one.
    def session_config(config)
      transcription = { model: config.api_model_id }
      transcription[:language] = @session.language if @session.language.present?

      {
        type: "transcription",
        audio: {
          input: {
            format: { type: "audio/pcm", rate: 24_000 },
            transcription: transcription,
            turn_detection: { type: "server_vad" }
          }
        }
      }
    end

    # client_secrets responds with either a bare string or { value: ... } across
    # API revisions; accept both.
    def extract_token(resp)
      cs = resp["client_secret"]
      return cs if cs.is_a?(String)
      return cs["value"] if cs.is_a?(Hash)

      resp["value"]
    end

    def openai_host?(base_url)
      URI(base_url.to_s).host.to_s.downcase.end_with?("api.openai.com")
    rescue URI::InvalidURIError
      false
    end

    def connection(config)
      Faraday.new(url: config.base_url) do |f|
        f.request :json
        f.response :json
        f.response :raise_error
        f.options.timeout = 15
        f.headers["Authorization"] = "Bearer #{config.api_key}"
        f.headers["OpenAI-Organization"] = config.organization_id if config.organization_id
      end
    end
  end
end
