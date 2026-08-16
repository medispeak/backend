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

    # finish_reasons meaning the model stopped because it was DONE. Anthropic
    # says "end_turn", OpenAI says "stop"; anything else ("max_tokens",
    # "length", a refusal) means the output is partial.
    OCR_COMPLETE = %w[stop end_turn].freeze

    private

    # A truncated extraction arrives as a 200 carrying half a lab report, and
    # nothing downstream can tell the difference — structuring reads it, the
    # session goes :completed, and a clinician sees a green result over a
    # partial document.
    #
    # This lives in the base class so both vision adapters enforce one rule, and
    # is called from inside the adapter (not from OcrStage) deliberately: only a
    # raise that happens DURING the attempt is visible to Llm::Caller, which is
    # what turns a truncation into a fallback attempt on the secondary provider
    # rather than an immediate session failure. BadResponse is one of
    # Caller::TRANSIENT for exactly that reason.
    # `usage` is passed through onto the error because a truncated response is a
    # response: the provider counted those tokens and will bill them. Carrying
    # it lets the orchestrator record the attempt rather than absorb the cost.
    def guard_ocr_completion!(finish_reason, usage: nil, latency_ms: nil)
      return if finish_reason.nil? || OCR_COMPLETE.include?(finish_reason.to_s)

      raise Llm::BadResponse.new(
        "OCR did not complete (finish_reason=#{finish_reason}); " \
        "the document was too long for the model's output budget",
        usage: usage, latency_ms: latency_ms,
        provider: config.provider_name || config.provider_kind.to_s,
        model: config.api_model_id
      )
    end

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
