class FormField < ApplicationRecord
  include JsonObjectColumns

  belongs_to :page

  # Edited as JSON text in the admin UI; see JsonObjectColumns.
  json_object_columns :metadata

  # Using string enum for better readability
  enum :field_type, {
    string: "string",           # Text input
    number: "number",           # Numeric input
    boolean: "boolean",         # Yes/No values
    single_select: "single_select",   # Single choice from options
    multi_select: "multi_select"      # Multiple choices from options
  }

  validates :title, presence: true
  validates :friendly_name, presence: true
  validates :field_type, presence: true
  validate :validate_select_options
  validate :validate_number_constraints

  # Virtual attribute for enum options
  attr_writer :enum_options_raw

  def enum_options_raw
    @enum_options_raw || enum_options&.join("\n")
  end

  before_validation :process_enum_options

  def to_json_schema_for_ai
    schema = {
      type: json_schema_type,
      description: description
    }

    case field_type
    when "single_select", "multi_select"
      schema[:enum] = enum_options if enum_options.present?
    when "number"
      schema[:minimum] = minimum if minimum.present?
      schema[:maximum] = maximum if maximum.present?
    end

    schema.compact
  end

  private

  def json_schema_type
    case field_type
    when "single_select"
      "string"
    when "multi_select"
      "array"
    else
      field_type
    end
  end

  def validate_select_options
    return unless [ "single_select", "multi_select" ].include?(field_type)

    if enum_options.blank? || enum_options.any?(&:blank?)
      errors.add(:enum_options, "must have at least one non-empty option for select fields")
    end
  end

  def validate_number_constraints
    return unless field_type == "number"

    if minimum.present? && maximum.present? && maximum.to_f < minimum.to_f
      errors.add(:maximum, "must be greater than minimum")
    end
  end

  def process_enum_options
    return unless @enum_options_raw.present?

    # Split by newlines, remove empty lines and whitespace
    self.enum_options = @enum_options_raw
      .split("\n")
      .map(&:strip)
      .reject(&:blank?)
      .uniq
  end
end
