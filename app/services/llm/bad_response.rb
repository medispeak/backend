module Llm
  # Raised on non-2xx responses or unparseable provider output. Triggers fallback.
  class BadResponse < Error; end
end
