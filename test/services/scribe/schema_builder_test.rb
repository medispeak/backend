# Standalone unit tests for Scribe::SchemaBuilder.
# Runnable without Rails/DB: `ruby -Itest test/services/scribe/schema_builder_test.rb`
require "minitest/autorun"
require "json_schemer"

# Standalone mode loads the file directly; under `bin/rails test` Zeitwerk
# autoloads Scribe::SchemaBuilder, so skip the manual load.
unless defined?(Rails)
  require_relative "#{File.expand_path('../../../app/services/scribe', __dir__)}/schema_builder"
end

# Duck-typed stand-in for FormField (no ActiveRecord / DB needed).
Field = Struct.new(:title, :friendly_name, :description, :field_type,
                   :enum_options, :minimum, :maximum, keyword_init: true)

class SchemaBuilderTest < Minitest::Test
  def build(fields, context: {})
    Scribe::SchemaBuilder.new(fields: fields, context: context).call
  end

  def test_string_field
    schema = build([ Field.new(title: "name", friendly_name: "Name", field_type: "string") ])
    prop = schema[:properties]["name"]
    assert_equal [ "string", "null" ], prop[:type]
    assert_equal "Name", prop[:description]
  end

  def test_boolean_and_number_types
    schema = build([
      Field.new(title: "smoker", friendly_name: "Smoker", field_type: "boolean"),
      Field.new(title: "age", friendly_name: "Age", field_type: "number")
    ])
    assert_equal [ "boolean", "null" ], schema[:properties]["smoker"][:type]
    assert_equal [ "number", "null" ], schema[:properties]["age"][:type]
  end

  def test_single_select_emits_enum_on_string
    schema = build([ Field.new(title: "sev", friendly_name: "Severity",
                              field_type: "single_select", enum_options: %w[low high]) ])
    prop = schema[:properties]["sev"]
    assert_equal [ "string", "null" ], prop[:type]
    assert_equal [ "low", "high", nil ], prop[:enum]
  end

  def test_single_select_enum_dedupes_when_options_already_include_nil
    schema = build([ Field.new(title: "sev", friendly_name: "Severity",
                              field_type: "single_select", enum_options: [ "low", "high", nil ]) ])
    assert_equal [ "low", "high", nil ], schema[:properties]["sev"][:enum]
  end

  # The bug being fixed: multi_select must put enum on items, not the array.
  def test_multi_select_emits_items_enum_not_array_enum
    schema = build([ Field.new(title: "symptoms", friendly_name: "Symptoms",
                              field_type: "multi_select", enum_options: %w[cough fever]) ])
    prop = schema[:properties]["symptoms"]
    assert_equal [ "array", "null" ], prop[:type]
    assert_nil prop[:enum], "enum must NOT be on the array itself"
    assert_equal({ type: "string", enum: %w[cough fever] }, prop[:items])
  end

  def test_number_min_max_injected_into_description
    schema = build([ Field.new(title: "bp", friendly_name: "BP", field_type: "number",
                              minimum: "60", maximum: "200") ])
    desc = schema[:properties]["bp"][:description]
    assert_includes desc, "Minimum: 60"
    assert_includes desc, "Maximum: 200"
  end

  def test_context_appended_to_description
    schema = build(
      [ Field.new(title: "name", friendly_name: "Name", field_type: "string") ],
      context: { "name" => "Patient full legal name" }
    )
    assert_includes schema[:properties]["name"][:description], "Context: Patient full legal name"
  end

  def test_description_prefers_explicit_description_over_friendly_name
    schema = build([ Field.new(title: "x", friendly_name: "Friendly",
                              description: "Explicit help", field_type: "string") ])
    assert_equal "Explicit help", schema[:properties]["x"][:description]
  end

  # enum and type must BOTH be satisfied, so a nullable type with null missing
  # from the enum still forbids null — and the model must invent a value.
  def test_a_single_select_can_actually_be_null
    prop = build([ Field.new(title: "sev", friendly_name: "Severity",
                             field_type: "single_select", enum_options: %w[low high]) ])[:properties]["sev"]
    schemer = JSONSchemer.schema(JSON.parse({ type: "object", properties: { sev: prop }, required: [] }.to_json))

    assert schemer.valid?({ "sev" => nil }), "a single_select must be able to abstain"
    assert schemer.valid?({ "sev" => "low" }), "a real option must still validate"
    refute schemer.valid?({ "sev" => "medium" }), "the enum must still reject values outside it"
  end

  def test_a_multi_select_can_be_null_without_loosening_its_item_enum
    prop = build([ Field.new(title: "sx", friendly_name: "Symptoms",
                             field_type: "multi_select", enum_options: %w[cough fever]) ])[:properties]["sx"]
    schemer = JSONSchemer.schema(JSON.parse({ type: "object", properties: { sx: prop }, required: [] }.to_json))

    assert schemer.valid?({ "sx" => nil }), "the array itself may be absent"
    assert schemer.valid?({ "sx" => [] }), "an empty selection is legitimate"
    refute schemer.valid?({ "sx" => [ nil ] }), "null is NOT a valid member of the list"
    refute schemer.valid?({ "sx" => [ "sneeze" ] }), "items must still come from the enum"
  end

  def test_object_envelope
    schema = build([ Field.new(title: "x", friendly_name: "X", field_type: "string") ])
    assert_equal "object", schema[:type]
    assert_equal false, schema[:additionalProperties]
    assert_equal [], schema[:required]
  end
end
