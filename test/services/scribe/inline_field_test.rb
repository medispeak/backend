require "test_helper"

class Scribe::InlineFieldTest < ActiveSupport::TestCase
  test "from_payload maps key->title and label->friendly_name" do
    f = Scribe::InlineField.from_payload({ "key" => "hr", "label" => "Heart Rate", "type" => "number" })
    assert_equal "hr", f.title
    assert_equal "Heart Rate", f.friendly_name
    assert_equal "number", f.field_type
  end

  test "build_all feeds SchemaBuilder to a key-keyed, correct schema" do
    fields = Scribe::InlineField.build_all([
      { "key" => "hr", "label" => "Heart Rate", "type" => "number" },
      { "key" => "sx", "label" => "Symptoms", "type" => "multi_select", "enum" => %w[fever cough] }
    ])
    schema = Scribe::SchemaBuilder.new(fields: fields).call
    assert_equal [ "number", "null" ], schema[:properties]["hr"][:type]
    assert_equal [ "array", "null" ], schema[:properties]["sx"][:type]
    assert_equal %w[fever cough], schema[:properties]["sx"][:items][:enum]
  end

  test "validation_error flags bad payloads" do
    assert_nil Scribe::InlineField.validation_error([ { "key" => "a", "type" => "string" } ])
    assert_match(/non-empty/, Scribe::InlineField.validation_error([]))
    assert_match(/key/, Scribe::InlineField.validation_error([ { "type" => "string" } ]))
    assert_match(/duplicate/, Scribe::InlineField.validation_error([ { "key" => "a", "type" => "string" }, { "key" => "a", "type" => "string" } ]))
    assert_match(/invalid field type/, Scribe::InlineField.validation_error([ { "key" => "a", "type" => "date" } ]))
    assert_match(/enum/, Scribe::InlineField.validation_error([ { "key" => "a", "type" => "single_select" } ]))
  end
end
