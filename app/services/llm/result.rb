module Llm
  # Normalized result of a single adapter call. `text` is set by transcribe,
  # `structured` by structure; both carry `usage` so the caller/metering layer
  # never inspects provider-specific response shapes.
  Result = Struct.new(
    :text,
    :structured,
    :model,
    :provider,
    :usage,
    :latency_ms,
    :finish_reason,
    # Language the provider actually detected/produced (e.g. Sarvam returns
    # language_code; "en" after a translate). nil when the provider doesn't
    # report one — the ASR stage then falls back to the caller's language hint.
    :language,
    :raw,
    # Errors from attempts that were abandoned for a fallback provider but which
    # the provider still billed (a truncated or empty 200 carries usage). Set by
    # Llm::Caller when it falls back; the metering layer records each one so a
    # recovered call does not hide the cost of the attempt it recovered from.
    # Always an Array — nil-safe via #discarded.
    :discarded_attempts,
    keyword_init: true
  ) do
    def discarded
      Array(discarded_attempts)
    end
  end
end
