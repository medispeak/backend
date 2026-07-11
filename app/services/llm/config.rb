module Llm
  # Immutable, resolved configuration for one function call (asr/structuring/
  # combined). Built by ConfigResolver (DB) or DefaultConfigProvider (ENV).
  #
  # The API key is resolved lazily: pass either an `api_key` string or an
  # `api_key_resolver` callable (so resolver unit tests need no real key, and
  # decryption is deferred out of the resolver).
  class Config
    attr_reader :provider_kind, :provider_name, :api_model_id, :base_url,
                :organization_id, :request_timeout, :capabilities, :options,
                :fallback

    def initialize(provider_kind:, api_model_id:, base_url:,
                   provider_name: nil,
                   request_timeout: 120, organization_id: nil,
                   capabilities: {}, options: {}, fallback: nil,
                   api_key: nil, api_key_resolver: nil)
      @provider_kind = provider_kind.to_sym
      # Human-readable provider NAME (e.g. "OpenAI") — the price book keys on it,
      # and it's what the usage ledger should show. provider_kind alone is not
      # unique (OpenAI + OpenRouter are both :openai_compatible).
      @provider_name = provider_name
      @api_model_id = api_model_id
      @base_url = base_url
      @organization_id = organization_id
      @request_timeout = request_timeout
      @capabilities = capabilities || {}
      @options = options || {}
      @fallback = fallback
      @api_key_value = api_key
      @api_key_resolver = api_key_resolver
      freeze
    end

    # Lazily resolved so secrets are read/decrypted only when a call is made.
    def api_key
      @api_key_value || (@api_key_resolver && @api_key_resolver.call)
    end

    def capability?(name)
      !!@capabilities[name.to_sym] || !!@capabilities[name.to_s]
    end

    # ASR task mode, derived from the resolved assignment options:
    #   :transcribe (default) — keep the spoken language (incl. code-mix).
    #   :translate            — Whisper translates the audio to English.
    # Set options["asr_mode"] = "translate" on the ASR ModelAssignment (at any
    # scope: Page > Template > Account > System) for a client whose form fills
    # must be English — e.g. Malayalam/English code-mix consults feeding an
    # English EHR. Only Whisper-family models (OpenAI whisper-1, self-hosted
    # Whisper) support :translate, and it always targets English. Any absent or
    # unknown value falls back to the safe :transcribe default.
    def asr_mode
      (@options[:asr_mode] || @options["asr_mode"]).to_s == "translate" ? :translate : :transcribe
    end
  end
end
