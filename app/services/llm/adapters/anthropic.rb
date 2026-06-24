module Llm
  module Adapters
    # Adapter for Anthropic's Messages API. Anthropic has no audio endpoint, so
    # #transcribe always raises — providers carrying this adapter must have
    # capability can_transcribe = false, and the orchestrator routes ASR
    # elsewhere. Structured extraction is done via a single forced tool call
    # ("extraction") whose input_schema is the core JSON schema passed through
    # as-is: Anthropic supports a real required subset and JSON-schema-shaped
    # input_schema natively, so no nullable-everywhere transform is applied here.
    #
    # Unlike the OpenAI-compatible adapter (which leans on ruby-openai), this
    # talks to Anthropic over Faraday directly. The connection is built per
    # adapter instance from the Llm::Config; transport errors are mapped to the
    # Llm::Error hierarchy by the base adapter so callers never see raw HTTP.
    class Anthropic < Llm::Adapter
      ANTHROPIC_VERSION = "2023-06-01".freeze
      DEFAULT_MAX_TOKENS = 4096
      TOOL_NAME = "extraction".freeze

      # Anthropic exposes no audio transcription endpoint. The capability flag
      # can_transcribe is false for these providers; this guard makes a
      # misrouted call fail loudly rather than silently returning nothing.
      def transcribe(*)
        raise Llm::BadResponse, "Anthropic does not support audio transcription"
      end

      def structure(messages:, schema:, **_opts)
        started = monotonic

        response = client.post("/v1/messages", request_body(messages, schema))
        resp = response.body
        structured = extract_tool_input(resp)

        Llm::Result.new(
          structured: structured,
          model: config.api_model_id,
          provider: config.provider_kind.to_s,
          usage: usage_from(resp["usage"]),
          finish_reason: resp["stop_reason"],
          latency_ms: elapsed_ms(started),
          raw: resp
        )
      rescue Faraday::Error => e
        raise map_transport_error(e)
      end

      private

      def request_body(messages, schema)
        {
          model: config.api_model_id,
          max_tokens: config.options[:max_tokens] || DEFAULT_MAX_TOKENS,
          system: system_prompt(messages),
          messages: chat_messages(messages),
          tools: [
            {
              name: TOOL_NAME,
              description: "Extract structured data",
              input_schema: schema
            }
          ],
          tool_choice: { type: "tool", name: TOOL_NAME }
        }
      end

      # Anthropic takes the system message as a top-level string; only user and
      # assistant turns live in `messages`.
      def system_prompt(messages)
        msg = messages.find { |m| role_of(m).to_s == "system" }
        msg && content_of(msg)
      end

      def chat_messages(messages)
        messages
          .reject { |m| role_of(m).to_s == "system" }
          .map { |m| { role: role_of(m).to_s, content: content_of(m) } }
      end

      # Find the forced tool_use block and return its parsed input hash. A 2xx
      # response without the expected block is a bad response (e.g. truncation
      # or refusal), which triggers fallback upstream.
      def extract_tool_input(resp)
        blocks = resp["content"]
        unless blocks.is_a?(Array)
          raise Llm::BadResponse, "Anthropic response missing content blocks"
        end

        block = blocks.find do |b|
          b.is_a?(Hash) && b["type"] == "tool_use" && b["name"] == TOOL_NAME
        end
        unless block
          raise Llm::BadResponse, "Anthropic response missing #{TOOL_NAME} tool_use block"
        end

        block["input"]
      end

      def usage_from(usage)
        return Llm::Usage.new(estimated: true) if usage.nil?

        Llm::Usage.new(
          input_tokens: usage["input_tokens"],
          output_tokens: usage["output_tokens"]
        )
      end

      def role_of(message)
        message[:role] || message["role"]
      end

      def content_of(message)
        message[:content] || message["content"]
      end

      def client
        @client ||= Faraday.new(url: config.base_url) do |f|
          f.request :json
          f.response :json
          f.response :raise_error
          f.options.timeout = config.request_timeout
          f.headers["x-api-key"] = config.api_key
          f.headers["anthropic-version"] = ANTHROPIC_VERSION
          f.headers["content-type"] = "application/json"
        end
      end
    end
  end
end
