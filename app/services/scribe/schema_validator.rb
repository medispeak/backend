module Scribe
  # Validates structured-output against the FULL schema (including the
  # minimum/maximum/enum constraints that strict decoding engines ignore) and
  # supports exactly one bounded repair re-ask (the Instructor pattern).
  #
  # Keys are normalized to strings so it works whether callers pass symbol-keyed
  # schemas (from SchemaBuilder) or string-keyed data (parsed model JSON).
  class SchemaValidator
    def initialize(schema)
      @schemer = JSONSchemer.schema(deep_stringify(schema))
    end

    def valid?(data)
      errors(data).empty?
    end

    def errors(data)
      normalized = normalize(data)
      @schemer.validate(normalized).map { |e| format_error(e) } +
        malformed_json_string_errors(normalized)
    end

    # Returns [data, []] when valid. When invalid and a block is given, calls the
    # block once with the errors, re-validates its result, and returns
    # [repaired, remaining_errors]. Without a block, returns [data, errors].
    def validate_and_repair(data)
      errs = errors(data)
      return [ data, [] ] if errs.empty?
      return [ data, errs ] unless block_given?

      repaired = yield(errs)
      [ repaired, errors(repaired) ]
    end

    private

    def format_error(err)
      {
        pointer: err["data_pointer"],
        type: err["type"],
        message: err["error"] || "#{err['data_pointer']} failed #{err['type']} validation"
      }
    end

    # Callers embed nested structured sub-data (medication, diagnosis, …) as a
    # JSON-encoded string inside an otherwise plain "string" field — a shape
    # the JSON Schema itself can't constrain. A reasoning model occasionally
    # leaks scratchpad text after (or instead of) the real JSON there, which
    # is schema-valid (still a string) but unusable. Treat a value that looks
    # like JSON but doesn't fully parse as a validation failure so it goes
    # through the same bounded repair re-ask as any other error.
    def malformed_json_string_errors(data)
      return [] unless data.is_a?(Hash)

      data.each_with_object([]) do |(key, value), errs|
        next unless value.is_a?(String)

        trimmed = value.strip
        next unless looks_like_json_payload?(trimmed)

        begin
          JSON.parse(trimmed)
        rescue JSON::ParserError
          errs << {
            pointer: "/#{key}",
            type: "malformed_json_string",
            message: "value at /#{key} looks like malformed or truncated JSON"
          }
        end
      end
    end

    # A leading [ or { alone also matches plain-text answers like
    # "[not mentioned]" or "{pending}" — require an actual "key": shape too,
    # so only a real (but broken) object/array payload is flagged.
    def looks_like_json_payload?(text)
      text.start_with?("[", "{") && text.include?('":')
    end

    def deep_stringify(obj)
      case obj
      when Hash  then obj.each_with_object({}) { |(k, v), h| h[k.to_s] = deep_stringify(v) }
      when Array then obj.map { |v| deep_stringify(v) }
      else obj
      end
    end

    # Round-trip through JSON so symbol-keyed Ruby hashes become string-keyed,
    # which is what JSON Schema validation expects.
    def normalize(data)
      JSON.parse(data.is_a?(String) ? data : JSON.generate(data))
    end
  end
end
