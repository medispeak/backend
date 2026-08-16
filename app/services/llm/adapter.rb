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
    # finish_reasons meaning the model DECLINED: Anthropic's "refusal", the
    # OpenAI family's "content_filter". Distinct from truncation — a bigger
    # budget will not help, and Llm::Caller does not fall back on a refusal.
    OCR_REFUSED = %w[refusal content_filter].freeze

    # The largest completion an adapter's models are assumed to accept when the
    # model itself does not say. Providers reject — with a 400, before doing any
    # work — a request whose output budget exceeds the model's ceiling, so a
    # budget sized only from the page count would fail every long document
    # outright rather than attempt it. Concrete adapters override this with the
    # floor of their current model line; a model that allows more declares it in
    # capabilities.max_output_tokens (see #ocr_output_ceiling).
    DEFAULT_OUTPUT_CEILING = 4096

    private

    # Caps an OCR output budget at what THIS model will accept. Applied per
    # adapter (rather than once in OcrStage) because a primary and its fallback
    # can be different models with different ceilings while receiving the same
    # requested budget: gpt-4o-mini takes 16k, an older Claude 8k, and the
    # fallback attempt must not 400 on a number that suited the primary.
    #
    # The ceiling comes from the model's capabilities.max_output_tokens when an
    # admin has recorded it, else the adapter's conservative default. It is a
    # MODEL property and is read only from the model row, never from the
    # assignment's options: ConfigResolver hands the primary assignment's
    # options to the fallback Config as well, so an options-declared ceiling
    # would be applied to a different model on the fallback path — exactly the
    # over-ceiling 400 this clamp exists to prevent. A too-low ceiling degrades
    # to an honest truncation failure (guard_ocr_completion!, then fallback); a
    # too-high one is a hard 400 — which is why the defaults are conservative.
    def clamp_ocr_budget(max_tokens)
      return nil if max_tokens.nil?

      [ max_tokens.to_i, ocr_output_ceiling ].min
    end

    def ocr_output_ceiling
      declared = config.capabilities[:max_output_tokens].to_i
      declared.positive? ? declared : self.class::DEFAULT_OUTPUT_CEILING
    end

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

      # A refusal is not a truncation: telling the client "the document was too
      # long" would send them looking at the wrong thing, and Llm::Refused is
      # outside Caller::TRANSIENT, so it is not retried on the fallback — a
      # refusal is a decision, not a fault. Still billed, so it carries usage.
      if OCR_REFUSED.include?(finish_reason.to_s)
        raise Llm::Refused.new(
          "OCR was refused by the provider (finish_reason=#{finish_reason})",
          usage: usage, latency_ms: latency_ms,
          provider: config.provider_name || config.provider_kind.to_s,
          model: config.api_model_id
        )
      end

      raise billed_ocr_error(
        "OCR did not complete (finish_reason=#{finish_reason}); " \
        "the document was too long for the model's output budget",
        usage: usage, latency_ms: latency_ms
      )
    end

    # A BadResponse for a 200 the provider will bill us for but that we cannot
    # use (truncated, empty, malformed). One constructor so every vision adapter
    # tags the error with the same provider/model the ledger expects.
    def billed_ocr_error(message, usage: nil, latency_ms: nil)
      Llm::BadResponse.new(
        message, usage: usage, latency_ms: latency_ms,
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
