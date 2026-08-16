require "test_helper"

class FormFieldTest < ActiveSupport::TestCase
  # metadata is edited as JSON text in the admin UI (same trap as
  # ModelAssignment#options: a String persists as a JSON string scalar).
  test "metadata coerces JSON text into a Hash and rejects non-objects" do
    field = create(:form_field, metadata: '{"source": "import"}')
    assert_equal({ "source" => "import" }, field.reload.metadata)
    assert_equal "object", FormField.connection.select_value(
      "SELECT jsonb_typeof(metadata) FROM form_fields WHERE id = #{field.id}"
    )
    assert_equal({}, create(:form_field, metadata: nil).reload.metadata)

    bad = build(:form_field, metadata: "[1]")
    assert_not bad.valid?
    assert_includes bad.errors[:metadata], "must be a JSON object"
  end
end
