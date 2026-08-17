require "test_helper"

class AiModelTest < ActiveSupport::TestCase
  setup { @provider = create(:ai_provider) }

  def model(capabilities)
    create(:ai_model, ai_provider: @provider, capabilities: capabilities)
  end

  test "for_function finds only models carrying every required capability" do
    asr = model("accepts_audio" => true, "can_transcribe" => true)
    partial = model("accepts_audio" => true)
    vision = model("supports_vision" => true, "supports_pdf" => true)
    structuring = model("can_structure" => true)

    assert_equal [ asr ], AiModel.for_function("asr").to_a
    assert_equal [ vision ], AiModel.for_function("ocr").to_a
    assert_equal [ structuring ], AiModel.for_function("structuring").to_a
    assert_not_includes AiModel.for_function("asr"), partial
  end

  test "for_function accepts a symbol and returns nothing for an unknown function" do
    model("can_structure" => true)

    assert_equal 1, AiModel.for_function(:structuring).count
    assert_empty AiModel.for_function("telepathy")
  end

  # A model can serve more than one function; the list column shows all of them.
  test "functions lists every function a model can serve" do
    both = model("can_structure" => true, "supports_vision" => true)

    assert_equal %w[structuring ocr], both.functions
    assert both.serves?("ocr")
    assert_not both.serves?("asr")
  end

  test "a model with no capabilities serves nothing" do
    assert_empty model({}).functions
  end

  # The structuring requirement is deliberately just can_structure: the seeded
  # claude-3-5-haiku structures without supports_json_schema and must stay
  # discoverable.
  test "structuring does not require the full stamped capability set" do
    haiku_like = model("can_structure" => true, "supports_function_calling" => true)

    assert_includes AiModel.for_function("structuring"), haiku_like
  end

  test "the OCR models the catalog provisions are discoverable as OCR" do
    OpenrouterCatalog.provision!

    slugs = AiModel.for_function("ocr").pluck(:api_model_id)
    OpenrouterCatalog::OCR_MODELS.each_key { |slug| assert_includes slugs, slug }
  end
end
