module Llm
  # Raised when a model refuses to produce output (safety refusal). Surfaced to
  # the caller distinctly from a transport failure so it is not retried blindly.
  class Refused < Error; end
end
