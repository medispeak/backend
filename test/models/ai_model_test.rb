require "test_helper"

# `capabilities` is the same shape of jsonb column as ModelAssignment#options
# and is edited through the same admin JSON textarea, so it gets the same
# coercion + validation. Without it a String slips through, `capability?`
# silently returns garbage (String#[]), and Llm::ConfigResolver#symbolize crashes.
class AiModelTest < ActiveSupport::TestCase
  test "capabilities accepts a Hash unchanged" do
    model = create(:ai_model, capabilities: { "accepts_audio" => true, "can_transcribe" => true })
    assert_equal({ "accepts_audio" => true, "can_transcribe" => true }, model.reload.capabilities)
    assert model.capability?(:can_transcribe)
    assert_not model.capability?(:can_structure)
  end

  test "capabilities coerces a JSON object string into a Hash" do
    model = create(:ai_model, capabilities: '{"accepts_audio": true, "can_transcribe": true}')
    model.reload
    assert_equal({ "accepts_audio" => true, "can_transcribe" => true }, model.capabilities)
    assert_equal "object", jsonb_typeof(model)
    assert model.capability?(:can_transcribe)
  end

  test "capabilities treats a blank string or nil as an empty object" do
    assert_equal({}, create(:ai_model, capabilities: "").reload.capabilities)
    assert_equal({}, create(:ai_model, capabilities: nil).reload.capabilities)
  end

  test "capabilities rejects JSON that is not an object" do
    [ '"{}"', "[true]", "1", "nope", '{"accepts_audio" => true}' ].each do |bad|
      model = build(:ai_model, capabilities: bad)
      assert_not model.valid?, "expected #{bad.inspect} to be invalid"
      assert_includes model.errors[:capabilities], "must be a JSON object", "for #{bad.inspect}"
    end
  end

  private

  def jsonb_typeof(record)
    AiModel.connection.select_value(
      "SELECT jsonb_typeof(capabilities) FROM ai_models WHERE id = #{record.id}"
    )
  end
end
