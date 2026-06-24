module Scribe
  # The ASR function: audio -> a normalized transcript. Provider-agnostic; wraps
  # Llm::Caller.transcribe (which owns provider fallback). Duration is supplied
  # by the caller (measured via ffprobe/blob metadata) because most providers do
  # not return it and ASR is billed per minute.
  #
  # mode: :transcribe keeps the source language (portable across providers);
  # :translate yields English (whisper-1 only) — gate via capabilities upstream.
  class AsrStage
    Result = Struct.new(
      :text, :language, :duration_seconds, :model, :provider, :usage, :raw,
      keyword_init: true
    )

    def initialize(config:)
      @config = config
    end

    def call(audio_io, language: nil, mode: :transcribe, audio_seconds: 0)
      llm = Llm::Caller.transcribe(
        @config, audio_io,
        language: language, mode: mode, audio_seconds: audio_seconds
      )

      Result.new(
        text: llm.text,
        language: language,
        duration_seconds: audio_seconds,
        model: llm.model,
        provider: llm.provider,
        usage: llm.usage,
        raw: llm.raw
      )
    end
  end
end
