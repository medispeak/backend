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
      @schemer.valid?(normalize(data))
    end

    def errors(data)
      @schemer.validate(normalize(data)).map { |e| format_error(e) }
    end

    # Returns [data, []] when valid. When invalid and a block is given, calls the
    # block once with the errors, re-validates its result, and returns
    # [repaired, remaining_errors]. Without a block, returns [data, errors].
    def validate_and_repair(data)
      errs = errors(data)
      return [data, []] if errs.empty?
      return [data, errs] unless block_given?

      repaired = yield(errs)
      [repaired, errors(repaired)]
    end

    private

    def format_error(err)
      {
        pointer: err["data_pointer"],
        type: err["type"],
        message: err["error"] || "#{err['data_pointer']} failed #{err['type']} validation"
      }
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
