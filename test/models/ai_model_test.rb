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


  # --- function discovery -----------------------------------------------

  def discovery_model(capabilities)
    create(:ai_model, ai_provider: @discovery_provider ||= create(:ai_provider), capabilities: capabilities)
  end

  test "for_function finds only models carrying every required capability" do
    asr = discovery_model("accepts_audio" => true, "can_transcribe" => true)
    partial = discovery_model("accepts_audio" => true)
    vision = discovery_model("supports_vision" => true, "supports_pdf" => true)
    structuring = discovery_model("can_structure" => true)

    assert_equal [ asr ], AiModel.for_function("asr").to_a
    assert_equal [ vision ], AiModel.for_function("ocr").to_a
    assert_equal [ structuring ], AiModel.for_function("structuring").to_a
    assert_not_includes AiModel.for_function("asr"), partial
  end

  test "for_function accepts a symbol and returns nothing for an unknown function" do
    discovery_model("can_structure" => true)

    assert_equal 1, AiModel.for_function(:structuring).count
    assert_empty AiModel.for_function("telepathy")
  end

  # A model can serve more than one function; the list column shows all of them.
  test "functions lists every function a model can serve" do
    both = discovery_model("can_structure" => true, "supports_vision" => true)

    assert_equal %w[structuring ocr], both.functions
    assert both.serves?("ocr")
    assert_not both.serves?("asr")
  end

  test "a model with no capabilities serves nothing" do
    assert_empty discovery_model({}).functions
  end

  # The structuring requirement is deliberately just can_structure: the seeded
  # claude-3-5-haiku structures without supports_json_schema and must stay
  # discoverable.
  test "structuring does not require the full stamped capability set" do
    haiku_like = discovery_model("can_structure" => true, "supports_function_calling" => true)

    assert_includes AiModel.for_function("structuring"), haiku_like
  end

  test "the OCR models the catalog provisions are discoverable as OCR" do
    OpenrouterCatalog.provision!

    slugs = AiModel.for_function("ocr").pluck(:api_model_id)
    OpenrouterCatalog::OCR_MODELS.each_key { |slug| assert_includes slugs, slug }
  end

  private

  def jsonb_typeof(record)
    AiModel.connection.select_value(
      "SELECT jsonb_typeof(capabilities) FROM ai_models WHERE id = #{record.id}"
    )
  end
end
