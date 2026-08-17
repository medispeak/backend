# Standalone: `ruby -Itest test/services/scribe/schema_validator_test.rb`
require "minitest/autorun"
require "json_schemer"

unless defined?(Rails)
  require_relative "#{File.expand_path('../../../app/services/scribe', __dir__)}/schema_validator"
end

class SchemaValidatorTest < Minitest::Test
  SCHEMA = {
    type: "object",
    properties: {
      "age" => { type: "integer", minimum: 0, maximum: 120 },
      "severity" => { type: "string", enum: %w[low high] },
      "symptoms" => { type: "array", items: { type: "string", enum: %w[cough fever] } }
    },
    required: []
  }.freeze

  def validator
    Scribe::SchemaValidator.new(SCHEMA)
  end

  def test_valid_payload
    assert validator.valid?({ "age" => 30, "severity" => "low", "symptoms" => [ "cough" ] })
  end

  def test_maximum_enforced
    refute validator.valid?({ "age" => 200 })
    errs = validator.errors({ "age" => 200 })
    refute_empty errs
  end

  def test_enum_enforced
    refute validator.valid?({ "severity" => "medium" })
  end

  def test_multi_select_item_enum_enforced
    refute validator.valid?({ "symptoms" => [ "cough", "sneeze" ] })
  end

  def test_accepts_symbol_keyed_data
    assert validator.valid?({ age: 30 })
  end

  def test_repair_block_invoked_once_and_fixes
    invoked = 0
    data, errs = validator.validate_and_repair({ "age" => 200 }) do |_errors|
      invoked += 1
      { "age" => 100 }
    end
    assert_equal 1, invoked
    assert_empty errs
    assert_equal({ "age" => 100 }, data)
  end

  def test_returns_errors_without_block
    data, errs = validator.validate_and_repair({ "age" => 200 })
    assert_equal({ "age" => 200 }, data)
    refute_empty errs
  end

  def test_valid_payload_skips_repair
    invoked = 0
    _data, errs = validator.validate_and_repair({ "age" => 50 }) { |_| invoked += 1; {} }
    assert_equal 0, invoked
    assert_empty errs
  end

  # Reasoning-model leak: a string field holding JSON-encoded nested data
  # (e.g. a medication array) with trailing scratchpad text appended after it.
  def test_rejects_json_looking_string_with_trailing_garbage
    leaked = '[{"medicine":{"code":""}}] However I am not sure about the last character.'
    refute validator.valid?({ "notes" => leaked })
    errs = validator.errors({ "notes" => leaked })
    assert(errs.any? { |e| e[:type] == "malformed_json_string" })
  end

  def test_accepts_well_formed_json_string
    assert validator.valid?({ "notes" => '[{"medicine":{"code":""}}]' })
  end

  def test_plain_prose_string_is_not_flagged_as_malformed_json
    assert validator.valid?({ "notes" => "low" })
  end

  # A plain-text answer that happens to be bracket-wrapped (a stylistic
  # annotation, not a leaked structured payload) must not be flagged.
  def test_bracketed_plain_text_is_not_flagged_as_malformed_json
    assert validator.valid?({ "notes" => "[not mentioned]" })
    assert validator.valid?({ "notes" => "{pending}" })
  end

  # Observed in production: the payload is escaped a second time, so the string
  # holds literal backslash-quote and never parses.
  def test_rejects_double_escaped_json_string
    refute validator.valid?({ "notes" => '[{\"medicine\":{\"code\":\"\"}}]' })
  end

  # Truncated mid-payload — the model ran out of room.
  def test_rejects_truncated_json_string
    refute validator.valid?({ "notes" => '[{"medicine":{"code":"386661006","display' })
  end

  # Every field is optional, and OpenAI strict mode makes the model spell
  # "not mentioned" as an explicit null. Rejecting that was the single largest
  # source of structuring errors in production.
  def test_null_is_treated_as_absent_not_as_a_type_error
    assert validator.valid?({ "age" => nil, "severity" => nil, "symptoms" => nil })
    assert_empty validator.errors({ "age" => nil })
  end

  def test_null_does_not_trigger_a_repair_re_ask
    invoked = 0
    data, errs = validator.validate_and_repair({ "severity" => nil }) { |_| invoked += 1; {} }
    assert_equal 0, invoked
    assert_empty errs
    assert_equal({ "severity" => nil }, data)
  end

  # Dropping nulls is a validation-time concern only: the caller still persists
  # the model's payload verbatim, nulls included.
  def test_null_survives_into_the_returned_data
    data, = validator.validate_and_repair({ "age" => 30, "severity" => nil })
    assert_equal({ "age" => 30, "severity" => nil }, data)
  end

  # A null must not become an escape hatch past a real constraint on a
  # non-null sibling.
  def test_null_alongside_an_invalid_value_still_reports_that_value
    refute validator.valid?({ "severity" => nil, "age" => 200 })
  end

  # Field titles are free text, so the pointer needs RFC 6901 escaping to match
  # the pointers json_schemer produces for the same field.
  def test_malformed_json_pointer_is_rfc6901_escaped
    errs = validator.errors({ "Procedure / Surgery" => '[{"code":' })
    err = errs.find { |e| e[:type] == "malformed_json_string" }
    assert_equal "/Procedure ~1 Surgery", err[:pointer]
  end
end
