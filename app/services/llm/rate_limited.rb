module Llm
  # Raised on provider 429 responses. Triggers fallback.
  class RateLimited < Error; end
end
