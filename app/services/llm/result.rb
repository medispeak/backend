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
    keyword_init: true
  )
end
