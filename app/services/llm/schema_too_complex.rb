module Llm
  # Raised when a provider rejects a structured-output schema as too complex
  # (e.g. Anthropic strict caps). The structuring stage may split-and-merge.
  class SchemaTooComplex < Error; end
end
