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
      :latency_ms,
      keyword_init: true
    )

    # The API's portable "no hint" value (GET /api/v2/config advertises
    # languages en/hi/ta/auto). It is not a language code and must never reach
    # a provider: Sarvam turned it into "auto-IN" and 400'd every segment
    # (prod session 62, 2026-08-16); Whisper rejects it too.
    AUTO_DETECT = "auto".freeze

    def initialize(config:)
      @config = config
    end

    def call(audio_io, language: nil, mode: :transcribe, audio_seconds: 0)
      language = nil if language.to_s.casecmp?(AUTO_DETECT)

      llm = Llm::Caller.transcribe(
        @config, audio_io,
        language: language, mode: mode, audio_seconds: audio_seconds
      )

      Result.new(
        text: llm.text,
        # Prefer the language the provider actually detected (Sarvam reports it,
        # and it becomes "en" after a translate); fall back to the caller's hint
        # for providers that don't return one (e.g. Whisper via ruby-openai).
        language: llm.language || language,
        duration_seconds: audio_seconds,
        model: llm.model,
        provider: llm.provider,
        usage: llm.usage,
        raw: llm.raw,
        # Carried through so Metering::UsageRecorder can persist it. Without it
        # usage_events.latency_ms is NULL for every row and no one can compare
        # one ASR model against another after the fact.
        latency_ms: llm.latency_ms
      )
    end
  end
end
