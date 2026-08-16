# Declares jsonb columns that must always hold a JSON *object* (a Hash).
#
# Rails' jsonb type will happily persist a Ruby String as a JSON string
# scalar: `record.options = "{}"` stores `'"{}"'::jsonb` (jsonb_typeof =
# 'string'), which reads back as the String "{}" — not a Hash. Anything that
# then iterates it (Llm::ConfigResolver#symbolize) crashes with
# `undefined method 'each_with_object' for an instance of String`. That is
# exactly how the admin UI took production ASR down on 2026-08-16: its JSON
# textarea submits text, and nothing coerced it.
#
#   class ModelAssignment < ApplicationRecord
#     include JsonObjectColumns
#     json_object_columns :options
#   end
#
# For each declared column:
#   * assigning JSON text parses it (blank/nil -> {}), so form input and
#     programmatic Hash assignment both land as a Hash;
#   * anything that is not (or does not parse to) a JSON object is kept
#     as-is so validation can reject it with "must be a JSON object" instead
#     of silently persisting a scalar.
module JsonObjectColumns
  extend ActiveSupport::Concern

  class_methods do
    def json_object_columns(*columns)
      columns.each do |column|
        column = column.to_s

        define_method("#{column}=") do |value|
          super(JsonObjectColumns.coerce(value))
        end

        validate do
          value = public_send(column)
          errors.add(column, "must be a JSON object") unless value.is_a?(Hash)
        end
      end
    end
  end

  # Hash            -> itself
  # nil / blank str -> {}
  # JSON text       -> parsed value if it is an object, else the raw text
  # anything else   -> unchanged (validation rejects it)
  def self.coerce(value)
    case value
    when Hash then value
    when nil then {}
    when String
      return {} if value.strip.empty?

      parsed = JSON.parse(value)
      parsed.is_a?(Hash) ? parsed : value
    else
      value
    end
  rescue JSON::ParserError
    value
  end
end
