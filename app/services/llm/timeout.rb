module Llm
  # Raised when a provider request exceeds its timeout. Triggers fallback.
  class Timeout < Error; end
end
