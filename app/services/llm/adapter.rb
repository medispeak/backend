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
    # The provider's own error MESSAGE rides along: a bare "status 400" hides
    # the actual reason (bad language code, unsupported format, audio too
    # long...) and cost real diagnosis time in production. Only the human
    # message is extracted from JSON bodies (not request ids or the raw
    # payload) because this string is persisted to session/output errors and
    # is visible to API clients.
    def map_transport_error(err)
      response = err.respond_to?(:response) && err.response.is_a?(Hash) ? err.response : {}
      status = response[:status]

      return Llm::Timeout.new("request timed out") if timeout_error?(err) || status == 408
      return Llm::RateLimited.new("rate limited") if status == 429

      parts = []
      parts << "status #{status}" if status
      parts << error_detail(response[:body]) if status
      parts << err.message if status.nil?
      detail = parts.compact.reject(&:empty?).join(": ")
      Llm::BadResponse.new("provider request failed#{detail.empty? ? '' : " (#{detail})"}")
    end

    ERROR_DETAIL_LIMIT = 200

    # {"error":{"message":"..."}} / {"error":"..."} / {"message":"..."} ->
    # that message; anything else -> a whitespace-collapsed, truncated excerpt.
    def error_detail(body)
      parsed = body.is_a?(String) ? (JSON.parse(body) rescue nil) : body
      message = nil
      if parsed.is_a?(Hash)
        err = parsed["error"] || parsed[:error]
        message = err.is_a?(Hash) ? (err["message"] || err[:message]) : err
        message ||= parsed["message"] || parsed[:message]
      end
      raw = body.is_a?(String) ? body : (body.nil? ? "" : body.to_json)
      text = (message.is_a?(String) && !message.strip.empty? ? message : raw).gsub(/\s+/, " ").strip
      return nil if text.empty?

      text.length > ERROR_DETAIL_LIMIT ? "#{text[0, ERROR_DETAIL_LIMIT]}…" : text
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
