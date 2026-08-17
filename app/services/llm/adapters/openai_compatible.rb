module Llm
  module Adapters
    # Adapter for OpenAI and any OpenAI-compatible endpoint (Groq, vLLM, Ollama,
    # LM Studio, self-hosted Whisper, …). The only thing that changes between
    # them is the Config (base_url + api_model_id + key) — the call code is
    # identical, which is what makes "run your own model" a config row.
    #
    # ruby-openai builds URLs as File.join(uri_base, api_version, path), so
    # Config#base_url must be the HOST base (no trailing /v1); api_version
    # defaults to "v1". For an endpoint already rooted at /v1, set
    # options[:api_version] = "".
    class OpenaiCompatible < Llm::Adapter
      def transcribe(audio_io, language: nil, mode: :transcribe, audio_seconds: 0, **_opts)
        started = monotonic
        params = { model: config.api_model_id, file: audio_io }
        params[:language] = language if language && mode.to_sym == :transcribe

        response =
          if mode.to_sym == :translate
            client.audio.translate(parameters: params)
          else
            client.audio.transcribe(parameters: params)
          end

        Llm::Result.new(
          text: response["text"],
          model: config.api_model_id,
          provider: config.provider_name || config.provider_kind.to_s,
          usage: Llm::Usage.new(audio_seconds: audio_seconds),
          latency_ms: elapsed_ms(started),
          raw: response
        )
      rescue Faraday::Error => e
        raise map_transport_error(e)
      end

      # `documents` structures straight from the source file instead of from
      # already-extracted text (Llm::Config#ocr_mode :extract_and_structure).
      def structure(messages:, schema:, documents: nil, max_tokens: nil, **_opts)
        started = monotonic
        params = { model: config.api_model_id, messages: with_documents(messages, documents) }
        params[:response_format] = json_schema_format(schema) if config.capability?(:supports_json_schema)
        params[output_budget_param] = clamp_ocr_budget(max_tokens) if max_tokens

        response = client.chat(parameters: params)
        choice = response.dig("choices", 0) || {}
        finish_reason = choice["finish_reason"]
        content = choice.dig("message", "content")

        # A 200 that stopped early (e.g. "length") carries truncated content;
        # don't trust it. Surface as a transient BadResponse so Caller falls back
        # — mirrors the Anthropic adapter's missing-tool-block handling. With
        # documents attached this is the same guard the OCR path uses, so a
        # refusal is Llm::Refused and is not retried on the fallback.
        if documents.present?
          guard_ocr_completion!(finish_reason, usage: usage_from(response["usage"]),
                                               latency_ms: elapsed_ms(started))
        elsif finish_reason && !%w[stop].include?(finish_reason.to_s)
          raise Llm::BadResponse, "model did not complete (finish_reason=#{finish_reason})"
        end

        Llm::Result.new(
          structured: content && parse_json(content),
          model: config.api_model_id,
          provider: config.provider_name || config.provider_kind.to_s,
          usage: usage_from(response["usage"]),
          finish_reason: finish_reason,
          latency_ms: elapsed_ms(started),
          raw: response
        )
      rescue Faraday::Error => e
        raise map_transport_error(e)
      end

      # Document OCR through the chat endpoint with multimodal content parts:
      # images as base64 data-URL image_url parts, PDFs as base64 file parts
      # (gpt-4o/4.1 family). Returns the full extracted text as Result#text.
      # max_tokens is supplied by OcrStage, sized from the page count. Sending
      # none left the extraction capped at whatever the endpoint's default
      # happened to be, which for a multi-page report is a truncation waiting to
      # happen. The parameter NAME depends on the endpoint — see
      # #output_budget_param.
      def ocr(documents:, prompt: nil, max_tokens: nil, **_opts)
        started = monotonic
        parts = [ { type: "text", text: prompt.to_s } ]
        documents.each { |doc| parts << document_part(doc) }

        params = {
          model: config.api_model_id,
          messages: [ { role: "user", content: parts } ]
        }
        params[output_budget_param] = clamp_ocr_budget(max_tokens) if max_tokens
        response = client.chat(parameters: params)
        choice = response.dig("choices", 0) || {}
        finish_reason = choice["finish_reason"]
        text = choice.dig("message", "content")
        usage = usage_from(response["usage"])
        elapsed = elapsed_ms(started)

        # Shared with the Anthropic adapter (Llm::Adapter#guard_ocr_completion!)
        # so one rule decides what "complete" means for every vision provider.
        # Both raises carry the usage: an unusable 200 is still a billed one.
        guard_ocr_completion!(finish_reason, usage: usage, latency_ms: elapsed)
        raise billed_ocr_error("provider returned no OCR text", usage: usage, latency_ms: elapsed) if text.blank?

        Llm::Result.new(
          text: text,
          model: config.api_model_id,
          provider: config.provider_name || config.provider_kind.to_s,
          usage: usage,
          finish_reason: finish_reason,
          latency_ms: elapsed,
          raw: response
        )
      rescue Faraday::Error => e
        raise map_transport_error(e)
      end

      OPENAI_HOST = "api.openai.com".freeze
      # The gpt-4o family — including the default OCR model, gpt-4o-mini — caps
      # completions at 16,384 tokens and 400s anything above it. gpt-4.1 and the
      # reasoning models allow more; declare that in capabilities.max_output_tokens.
      DEFAULT_OUTPUT_CEILING = 16_384

      private

      # Which request field carries the OCR output budget.
      #
      # OpenAI deprecated `max_tokens` in favour of `max_completion_tokens` and
      # its newer models (the o-series, GPT-5) reject the old name outright, so
      # an OCR assignment to one of those would 400 on every call. Every current
      # OpenAI model accepts the new name. The wider OpenAI-compatible world has
      # not caught up uniformly — Ollama only knows `max_tokens`, OpenRouter
      # varies by route — so anything that is not api.openai.com keeps the name
      # that is universally understood there. Decided by host, not model id,
      # because the same model id can be reached through either kind of endpoint.
      def output_budget_param
        host = begin
          URI.parse(config.base_url.to_s).host
        rescue URI::InvalidURIError
          nil
        end
        host == OPENAI_HOST ? :max_completion_tokens : :max_tokens
      end

      # Prepends the source documents to the first user turn, so the model reads
      # the file and fills the schema in one call.
      def with_documents(messages, documents)
        return messages if documents.blank?

        parts = documents.map { |doc| document_part(doc) }
        first_user = messages.index { |m| (m[:role] || m["role"]).to_s == "user" }
        return messages unless first_user

        messages.each_with_index.map do |message, i|
          next message unless i == first_user

          text = message[:content] || message["content"]
          { role: "user", content: parts + [ { type: "text", text: text.to_s } ] }
        end
      end

      def document_part(doc)
        data_url = "data:#{doc[:content_type]};base64,#{Base64.strict_encode64(doc[:data])}"
        if doc[:content_type] == "application/pdf"
          { type: "file", file: { filename: doc[:filename].presence || "document.pdf", file_data: data_url } }
        else
          { type: "image_url", image_url: { url: data_url } }
        end
      end

      # A 200 whose content is not valid JSON is a truncated/garbled response,
      # not a transport error. Map it to a transient BadResponse so Caller falls
      # back — mirrors the Anthropic adapter.
      def parse_json(content)
        JSON.parse(content)
      rescue JSON::ParserError => e
        raise Llm::BadResponse, "provider returned unparseable JSON content: #{e.message}"
      end

      def client
        @client ||= OpenAI::Client.new(client_options)
      end

      def client_options
        opts = {
          access_token: config.api_key,
          uri_base: config.base_url,
          request_timeout: config.request_timeout
        }
        opts[:organization_id] = config.organization_id if config.organization_id
        opts[:api_version] = config.options[:api_version] if config.options.key?(:api_version)
        opts
      end

      def json_schema_format(core_schema)
        {
          type: "json_schema",
          json_schema: { name: "extraction", strict: true, schema: to_openai_strict(core_schema) }
        }
      end

      # OpenAI strict mode requires: additionalProperties:false, EVERY property
      # listed in `required`, and "optional" expressed as a nullable type union.
      # The core schema marks fields optional via `required: []`; here we promote
      # all keys to required and make their types nullable so the model may still
      # return null for unknown fields.
      def to_openai_strict(schema)
        return schema unless schema.is_a?(Hash) && schema[:properties].is_a?(Hash)

        props = schema[:properties].transform_values { |prop| nullable(prop) }
        schema.merge(
          additionalProperties: false,
          properties: props,
          required: props.keys.map(&:to_s)
        )
      end

      def nullable(prop)
        return prop unless prop.is_a?(Hash) && prop.key?(:type)

        type = prop[:type]
        new_type = type.is_a?(Array) ? (type | [ "null" ]) : [ type, "null" ]
        prop.merge(type: new_type)
      end

      def usage_from(usage)
        return Llm::Usage.new(estimated: true) if usage.nil?

        Llm::Usage.new(
          input_tokens: usage["prompt_tokens"] || usage["input_tokens"] || 0,
          output_tokens: usage["completion_tokens"] || usage["output_tokens"] || 0
        )
      end
    end
  end
end
