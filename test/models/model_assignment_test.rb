require "test_helper"

# `options` is a jsonb column that the admin UI edits as raw JSON text. Rails'
# jsonb type happily persists a Ruby String as a JSON *string* scalar
# (jsonb_typeof = 'string'), which then reaches Llm::ConfigResolver as a String
# and crashes every ASR/structuring/OCR call with
# `undefined method 'each_with_object' for an instance of String`
# (prod incident 2026-08-16). The model must therefore coerce a JSON-text
# assignment into a Hash and refuse anything that is not a JSON object.
class ModelAssignmentTest < ActiveSupport::TestCase
  test "options accepts a Hash unchanged" do
    ma = create(:model_assignment, options: { "asr_mode" => "translate" })
    assert_equal({ "asr_mode" => "translate" }, ma.reload.options)
    assert_equal "object", jsonb_typeof(ma)
  end

  test "options coerces a JSON object string into a Hash (what the admin textarea submits)" do
    ma = create(:model_assignment, options: '{"asr_mode": "translate", "language": "hi"}')
    assert_equal({ "asr_mode" => "translate", "language" => "hi" }, ma.reload.options)
    assert_equal "object", jsonb_typeof(ma)
  end

  test "options treats an empty/blank string as an empty object" do
    assert_equal({}, create(:model_assignment, options: "").reload.options)
    assert_equal({}, create(:model_assignment, options: "   \n", function: "asr").reload.options)
    assert_equal({}, create(:model_assignment, options: nil, function: "ocr").reload.options)
  end

  test "options rejects a JSON string that is not an object" do
    [ '"{}"', "[1, 2]", "42", "true", "null", "not json at all", '{"asr_mode" => "translate"}' ].each do |bad|
      ma = build(:model_assignment, options: bad)
      assert_not ma.valid?, "expected #{bad.inspect} to be invalid"
      assert_includes ma.errors[:options], "must be a JSON object", "for #{bad.inspect}"
    end
  end

  test "options rejects a non-Hash, non-String value" do
    ma = build(:model_assignment, options: [ 1, 2 ])
    assert_not ma.valid?
    assert_includes ma.errors[:options], "must be a JSON object"
  end

  # Defense in depth: the model coercion covers AR writers, but update_column /
  # update_all / raw SQL bypass it. The DB CHECK constraint (added by the
  # normalization migration) makes the incident write impossible at the source.
  test "the database rejects a JSON string scalar in options even via raw SQL" do
    ma = create(:model_assignment)
    assert_raises(ActiveRecord::StatementInvalid) do
      ModelAssignment.transaction(requires_new: true) do
        ModelAssignment.connection.execute(
          "UPDATE model_assignments SET options = '\"{}\"'::jsonb WHERE id = #{ma.id}"
        )
      end
    end
    assert_raises(ActiveRecord::StatementInvalid) do
      ModelAssignment.transaction(requires_new: true) { ma.update_column(:options, "{}") }
    end
    assert_equal({}, ma.reload.options)
  end

  private

  def jsonb_typeof(record)
    ModelAssignment.connection.select_value(
      "SELECT jsonb_typeof(options) FROM model_assignments WHERE id = #{record.id}"
    )
  end
end
