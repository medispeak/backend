require "test_helper"

class ScribeOutputTest < ActiveSupport::TestCase
  test "valid with a scribe_session, output_type, and status" do
    assert build(:scribe_output).valid?
  end

  test "belongs to a scribe_session" do
    session = create(:scribe_session)
    output = create(:scribe_output, scribe_session: session)
    assert_equal session, output.scribe_session
  end

  test "page is optional" do
    output = build(:scribe_output, page: nil)
    assert output.valid?
  end

  test "associates with a page when given one" do
    page = create(:page)
    output = create(:scribe_output, page: page)
    assert_equal page, output.page
  end

  test "output_type enum exposes transcript, form, and note" do
    assert_equal %w[transcript form note].sort, ScribeOutput.output_types.keys.sort
  end

  test "status enum exposes pending, success, partial, and failure" do
    assert_equal %w[pending success partial failure].sort, ScribeOutput.statuses.keys.sort
  end

  test "output_type predicates work" do
    output = build(:scribe_output, output_type: "form")
    assert output.form?
    assert_not output.note?
  end

  test "status predicates use a prefix and do not collide with output_type" do
    output = build(:scribe_output, output_type: "form", status: "partial")
    # status predicates are prefixed
    assert output.status_partial?
    assert_not output.status_success?
    # output_type predicates remain unprefixed and independent
    assert output.form?
    # the bare `partial?` predicate is NOT defined for status (no collision)
    assert_not output.respond_to?(:partial?)
  end

  test "output_type and status can both be partial without conflict" do
    # `partial` is a value in BOTH enums; the prefix keeps them distinct.
    assert_includes ScribeOutput.output_types.keys, "transcript"
    assert_includes ScribeOutput.statuses.keys, "partial"
    output = create(:scribe_output, output_type: "note", status: "partial")
    output.reload
    assert_equal "note", output.output_type
    assert_equal "partial", output.status
    assert output.note?
    assert output.status_partial?
  end

  test "requires an output_type" do
    output = build(:scribe_output, output_type: nil)
    assert_not output.valid?
    assert_includes output.errors[:output_type], "can't be blank"
  end

  test "requires a status" do
    output = build(:scribe_output)
    output.status = nil
    assert_not output.valid?
    assert_includes output.errors[:status], "can't be blank"
  end

  test "persists jsonb result and context" do
    output = create(
      :scribe_output,
      context: { "patient_name" => "Jane" },
      result: { "fields" => { "bp" => "120/80" } }
    )
    output.reload
    assert_equal "Jane", output.context["patient_name"]
    assert_equal "120/80", output.result["fields"]["bp"]
  end

  test "persists the jsonb result_errors column" do
    # The column is named `result_errors` (not `errors`) because `errors`
    # collides with ActiveModel::Errors and raises DangerousAttributeError at
    # class-load time. `result_errors` has a normal generated accessor.
    session = create(:scribe_session)
    output = ScribeOutput.new(scribe_session: session, output_type: "form", status: "failure")
    output.result_errors = [ { "code" => "validation_error", "field" => "bp" } ]
    output.save!
    output.reload
    assert_equal "validation_error", output.result_errors.first["code"]
  end

  test "result_errors column defaults to an empty array" do
    session = create(:scribe_session)
    output = ScribeOutput.create!(scribe_session: session, output_type: "form")
    assert_equal [], output.result_errors
  end
end
