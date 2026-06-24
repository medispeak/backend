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
    :raw,
    keyword_init: true
  )
end
