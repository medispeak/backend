module Scribe
  # Builds a provider-neutral CORE JSON Schema from a page's form fields.
  #
  # This is the single source of truth for structuring schemas. It deliberately
  # does NOT reuse FormField#to_json_schema_for_ai, which emits the wrong shape
  # for multi_select (`enum` on the array instead of on `items`) — rejected by
  # strict structured-output engines.
  #
  # Provider-specific transforms (OpenAI strict nullability/required, Anthropic
  # tool shape, Gemini responseSchema) live in the adapters, not here.
  #
  # Field objects are duck-typed: any object responding to #title,
  # #friendly_name, #description, #field_type, #enum_options, #minimum, #maximum
  # works (so this is unit-testable without ActiveRecord).
  class SchemaBuilder
    # Convenience for the common case of a persisted Page.
    def self.for_page(page, context: {})
      new(fields: page.form_fields.to_a, context: context).call
    end

    def initialize(fields:, context: {})
      @fields = Array(fields)
      @context = context || {}
    end

    def call
      {
        type: "object",
        additionalProperties: false,
        properties: @fields.each_with_object({}) { |f, h| h[f.title] = field_schema(f) },
        # Current product semantics: every field is optional. The OpenAI strict
        # adapter transform promotes these to required+nullable as that API
        # demands; the core schema stays honest about optionality.
        required: []
      }
    end

    private

    def field_schema(field)
      schema = { type: json_type(field), description: description_for(field) }

      case field.field_type.to_s
      when "single_select"
        schema[:enum] = Array(field.enum_options) if present?(field.enum_options)
      when "multi_select"
        items = { type: "string" }
        items[:enum] = Array(field.enum_options) if present?(field.enum_options)
        schema[:items] = items
      end

      schema.compact
    end

    def json_type(field)
      case field.field_type.to_s
      when "single_select" then "string"
      when "multi_select"  then "array"
      when "number"        then "number"
      when "boolean"       then "boolean"
      else "string"
      end
    end

    # min/max are NOT enforced by any strict engine, so they are injected into
    # the description as hints (and validated in Ruby post-call by SchemaValidator).
    # Per-field context (port of v1 smart_description) is appended here too.
    def description_for(field)
      parts = []
      parts << (present?(field.description) ? field.description : field.friendly_name)

      if field.field_type.to_s == "number"
        parts << "Minimum: #{field.minimum}" if present?(field.minimum)
        parts << "Maximum: #{field.maximum}" if present?(field.maximum)
      end

      ctx = context_for(field.title)
      parts << "Context: #{ctx}" if present?(ctx)

      parts.compact.join("; ")
    end

    def context_for(title)
      @context[title] || @context[title.to_s] || @context[title.to_sym]
    end

    def present?(value)
      return false if value.nil?
      return !value.strip.empty? if value.is_a?(String)
      return !value.empty? if value.respond_to?(:empty?)
      true
    end
  end
end
