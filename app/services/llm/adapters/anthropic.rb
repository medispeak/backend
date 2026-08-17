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
      # Every Claude 3.5+ model accepts at least 8k output tokens; the API 400s a
      # max_tokens above the model's ceiling. Newer lines allow far more (64k)
      # and should say so in capabilities.max_output_tokens.
      DEFAULT_OUTPUT_CEILING = 8_192

      # Anthropic exposes no audio transcription endpoint. The capability flag
      # can_transcribe is false for these providers; this guard makes a
      # misrouted call fail loudly rather than silently returning nothing.
      def transcribe(*)
        raise Llm::BadResponse, "Anthropic does not support audio transcription"
      end

      # `documents` structures straight from the source file instead of from
      # already-extracted text (Llm::Config#ocr_mode :extract_and_structure).
      def structure(messages:, schema:, documents: nil, max_tokens: nil, **_opts)
        started = monotonic

        response = client.post("/v1/messages", request_body(messages, schema, documents, max_tokens))
        resp = response.body
        # With documents attached this is the same completeness rule the OCR
        # path uses, so a truncation raises INSIDE the attempt (where Caller can
        # spend the fallback) and a refusal becomes Llm::Refused. tool_use is a
        # valid terminal stop reason for a forced-tool call.
        if documents.present? && resp["stop_reason"].to_s != "tool_use"
          guard_ocr_completion!(resp["stop_reason"], usage: usage_from(resp["usage"]),
                                                     latency_ms: elapsed_ms(started))
        end
        structured = extract_tool_input(resp)

        Llm::Result.new(
          structured: structured,
          model: config.api_model_id,
          provider: config.provider_name || config.provider_kind.to_s,
          usage: usage_from(resp["usage"]),
          finish_reason: resp["stop_reason"],
          latency_ms: elapsed_ms(started),
          raw: resp
        )
      rescue Faraday::Error => e
        raise map_transport_error(e)
      end

      # Document OCR via the Messages API with native image / document (PDF)
      # content blocks. Returns the full extracted text as Result#text.
      #
      # max_tokens is supplied by OcrStage, sized from the page count: the
      # DEFAULT_MAX_TOKENS below is a structuring budget and truncates a
      # multi-page report. Whether the response actually completed is checked
      # HERE, by the shared Llm::Adapter#guard_ocr_completion!, so the rule is
      # identical for every provider AND the raise happens inside the attempt,
      # where Llm::Caller can see it and spend the fallback.
      # OcrStage#guard_completion! is only the backstop.
      def ocr(documents:, prompt: nil, max_tokens: nil, **_opts)
        started = monotonic

        blocks = documents.map { |doc| document_block(doc) }
        blocks << { type: "text", text: prompt.to_s }

        response = client.post("/v1/messages", {
          model: config.api_model_id,
          max_tokens: clamp_ocr_budget(max_tokens) || config.options[:max_tokens] || DEFAULT_MAX_TOKENS,
          messages: [ { role: "user", content: blocks } ]
        })
        resp = response.body
        usage = usage_from(resp["usage"])
        # Measured once so the error metadata and the Result agree on what this
        # attempt cost in time.
        elapsed = elapsed_ms(started)
        # Ordered before #extract_text: a max_tokens stop still carries real
        # text, so the blank check below would wave it through.
        guard_ocr_completion!(resp["stop_reason"], usage: usage, latency_ms: elapsed)
        text = extract_text(resp, usage: usage, latency_ms: elapsed)

        Llm::Result.new(
          text: text,
          model: config.api_model_id,
          provider: config.provider_name || config.provider_kind.to_s,
          usage: usage,
          finish_reason: resp["stop_reason"],
          latency_ms: elapsed,
          raw: resp
        )
      rescue Faraday::Error => e
        raise map_transport_error(e)
      end

      private

      def document_block(doc)
        source = {
          type: "base64",
          media_type: doc[:content_type],
          data: Base64.strict_encode64(doc[:data])
        }
        { type: doc[:content_type] == "application/pdf" ? "document" : "image", source: source }
      end

      # Joined text blocks. A 2xx with no text is a bad response (a refusal, or
      # a completion that spent its budget on nothing) and triggers fallback
      # upstream. It is still a billed round-trip, so the usage rides along on
      # the error for the ledger.
      def extract_text(resp, usage: nil, latency_ms: nil)
        blocks = resp["content"]
        unless blocks.is_a?(Array)
          raise billed_ocr_error("Anthropic response missing content blocks", usage: usage, latency_ms: latency_ms)
        end

        text = blocks.select { |b| b.is_a?(Hash) && b["type"] == "text" }
                     .map { |b| b["text"] }.join("\n")
        if text.blank?
          raise billed_ocr_error("Anthropic response contained no OCR text", usage: usage, latency_ms: latency_ms)
        end

        text
      end

      def request_body(messages, schema, documents = nil, max_tokens = nil)
        {
          model: config.api_model_id,
          max_tokens: clamp_ocr_budget(max_tokens) || config.options[:max_tokens] || DEFAULT_MAX_TOKENS,
          system: system_prompt(messages),
          messages: with_documents(chat_messages(messages), documents),
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

      # Prepends the source documents to the first user turn, so the model reads
      # the file and fills the schema in one call.
      def with_documents(messages, documents)
        return messages if documents.blank?

        blocks = documents.map { |doc| document_block(doc) }
        first_user = messages.index { |m| m[:role].to_s == "user" }
        return messages unless first_user

        messages.each_with_index.map do |message, i|
          next message unless i == first_user

          { role: "user", content: blocks + [ { type: "text", text: message[:content].to_s } ] }
        end
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
