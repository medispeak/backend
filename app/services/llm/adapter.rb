module Llm
  # Abstract base for provider adapters. Concrete adapters implement #transcribe
  # and/or #structure and MUST return a normalized Llm::Result carrying usage.
  # Transport (Faraday) errors are mapped to the Llm::Error hierarchy here so
  # callers never see provider/transport internals.
  class Adapter
    attr_reader :config

    def initialize(config)
      @config = config
    end

    def transcribe(*)
      raise NotImplementedError, "#{self.class} must implement #transcribe"
    end

    def structure(*)
      raise NotImplementedError, "#{self.class} must implement #structure"
    end

    # documents: [{ data: <bytes>, content_type:, filename: }] -> full extracted
    # text as Result#text. Vision-capable adapters implement this; others raise
    # so a misrouted call fails loudly (mirrors Anthropic#transcribe).
    def ocr(documents:, prompt: nil, **)
      raise Llm::BadResponse, "#{self.class.name.demodulize} does not support document OCR"
    end

    private

    # Maps a Faraday error (raised via `f.response :raise_error`) to an Llm error.
    # Mapped by HTTP status where available, falling back to exception class.
    def map_transport_error(err)
      status = err.respond_to?(:response) && err.response.is_a?(Hash) ? err.response[:status] : nil

      return Llm::Timeout.new("request timed out") if timeout_error?(err) || status == 408
      return Llm::RateLimited.new("rate limited") if status == 429

      Llm::BadResponse.new("provider request failed#{status ? " (status #{status})" : ''}")
    end

    def timeout_error?(err)
      defined?(Faraday::TimeoutError) && err.is_a?(Faraday::TimeoutError)
    end

    def monotonic
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end

    def elapsed_ms(start)
      ((monotonic - start) * 1000).round
    end
  end
end
