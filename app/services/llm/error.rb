module Llm
  # Base for all provider-abstraction errors. Adapters rescue transport
  # (Faraday) errors and re-raise these so callers never see provider internals.
  class Error < StandardError; end
end
