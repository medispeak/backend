module Llm
  # Base for all provider-abstraction errors. Adapters rescue transport
  # (Faraday) errors and re-raise these so callers never see provider internals.
  #
  # An error raised AFTER the provider returned a usable-looking 200 — a
  # truncated extraction, an empty completion — carries that response's usage.
  # The provider bills for those tokens whether or not we could use the result,
  # so the attempt is still real spend and the ledger should show it. Transport
  # failures (timeout, 5xx, connection reset) leave these nil: nothing was
  # returned, nothing was billed, nothing to record.
  class Error < StandardError
    attr_reader :usage, :provider, :model, :latency_ms

    def initialize(message = nil, usage: nil, provider: nil, model: nil, latency_ms: nil)
      super(message)
      @usage = usage
      @provider = provider
      @model = model
      @latency_ms = latency_ms
    end

    # Whether the provider returned something it will charge us for.
    def billable?
      !usage.nil?
    end
  end
end
