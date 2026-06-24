module Llm
  # Builds a Config from ENV when no DB ModelAssignment exists. This is the
  # backward-compatible bootstrap path: it reproduces today's OpenAI defaults so
  # the system behaves identically until operators add DB-backed config.
  #
  # ENV -> Config mapping (design spec 4.2):
  #   OPENAI_ACCESS_TOKEN     -> api_key
  #   OPENAI_ORGANIZATION_ID  -> organization_id
  #   (default)               -> openai_compatible @ https://api.openai.com/
  class DefaultConfigProvider
    OPENAI_BASE = "https://api.openai.com/".freeze

    DEFAULT_MODELS = {
      asr: "whisper-1",
      structuring: "gpt-4o-mini"
    }.freeze

    def self.call(function:, fallback: nil)
      new(function: function, fallback: fallback).call
    end

    def initialize(function:, fallback: nil)
      @function = function.to_sym
      @fallback = fallback
    end

    def call
      Llm::Config.new(
        provider_kind: :openai_compatible,
        api_model_id: DEFAULT_MODELS.fetch(@function),
        base_url: OPENAI_BASE,
        organization_id: ENV["OPENAI_ORGANIZATION_ID"],
        api_key_resolver: -> { ENV["OPENAI_ACCESS_TOKEN"] },
        capabilities: capabilities_for(@function),
        fallback: @fallback
      )
    end

    private

    def capabilities_for(function)
      case function
      when :asr
        { accepts_audio: true, can_transcribe: true }
      when :structuring
        { can_structure: true, supports_json_schema: true, supports_function_calling: true }
      else
        {}
      end
    end
  end
end
