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
          provider: config.provider_kind.to_s,
          usage: Llm::Usage.new(audio_seconds: audio_seconds),
          latency_ms: elapsed_ms(started),
          raw: response
        )
      rescue Faraday::Error => e
        raise map_transport_error(e)
      end

      def structure(messages:, schema:, **_opts)
        started = monotonic
        params = { model: config.api_model_id, messages: messages }
        params[:response_format] = json_schema_format(schema) if config.capability?(:supports_json_schema)

        response = client.chat(parameters: params)
        choice = response.dig("choices", 0) || {}
        finish_reason = choice["finish_reason"]
        content = choice.dig("message", "content")

        # A 200 that stopped early (e.g. "length") carries truncated content;
        # don't trust it. Surface as a transient BadResponse so Caller falls back
        # — mirrors the Anthropic adapter's missing-tool-block handling.
        if finish_reason && !%w[stop].include?(finish_reason.to_s)
          raise Llm::BadResponse, "model did not complete (finish_reason=#{finish_reason})"
        end

        Llm::Result.new(
          structured: content && parse_json(content),
          model: config.api_model_id,
          provider: config.provider_kind.to_s,
          usage: usage_from(response["usage"]),
          finish_reason: finish_reason,
          latency_ms: elapsed_ms(started),
          raw: response
        )
      rescue Faraday::Error => e
        raise map_transport_error(e)
      end

      private

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
        new_type = type.is_a?(Array) ? (type | ["null"]) : [type, "null"]
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
