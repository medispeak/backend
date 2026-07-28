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
end
