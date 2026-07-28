module Llm
  # Normalized usage for a single provider call. Adapters translate each
  # provider's idiosyncratic usage block into this shape; metering only ever
  # reads this struct, never raw provider responses.
  class Usage
    attr_reader :input_tokens, :output_tokens, :audio_seconds, :pages, :estimated

    def initialize(input_tokens: 0, output_tokens: 0, audio_seconds: 0, pages: 0, estimated: false)
      @input_tokens = input_tokens.to_i
      @output_tokens = output_tokens.to_i
      @audio_seconds = audio_seconds.to_f
      @pages = pages.to_i
      @estimated = estimated
    end

    def total_tokens
      input_tokens + output_tokens
    end

    def to_h
      {
        input_tokens: input_tokens,
        output_tokens: output_tokens,
        total_tokens: total_tokens,
        audio_seconds: audio_seconds,
        pages: pages,
        estimated: estimated
      }
    end
  end
end
