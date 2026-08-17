require "test_helper"

class OpenaiCatalogTest < ActiveSupport::TestCase
  test "provision! is a no-op when the OpenAI provider does not exist" do
    assert_no_difference([ "AiModel.count", "ModelPrice.count" ]) do
      assert_nil OpenaiCatalog.provision!
    end
  end

  test "provision! creates each model with its capabilities and a token price" do
    provider = create(:ai_provider, name: "OpenAI", base_url: "https://api.openai.com/")
    OpenaiCatalog.provision!

    OpenaiCatalog::MODELS.each do |slug, attrs|
      model = AiModel.find_by!(ai_provider: provider, api_model_id: slug)
      assert_equal attrs[:display_name], model.display_name
      assert_equal attrs[:capabilities], model.capabilities

      price = ModelPrice.current.find_by(provider: "OpenAI", model: slug)
      assert price, "token price for #{slug}"
      assert_equal attrs[:input_per_million], price.input_per_million.to_f
    end
  end

  test "the models it provisions serve both OCR and structuring" do
    create(:ai_provider, name: "OpenAI", base_url: "https://api.openai.com/")
    OpenaiCatalog.provision!

    OpenaiCatalog::MODELS.each_key do |slug|
      model = AiModel.find_by!(api_model_id: slug)
      assert model.capability?(:supports_vision), "#{slug} must be usable for OCR"
      assert model.capability?(:supports_pdf), slug
      assert model.capability?(:can_structure), "#{slug} must be usable for structuring"
      # OcrStage asks for up to MAX_MAX_TOKENS; a ceiling below that would make
      # the adapter clamp a long report for no reason.
      assert_operator model.capabilities["max_output_tokens"], :>=,
                      Scribe::OcrStage::MAX_MAX_TOKENS, slug
    end
  end

  test "provision! is idempotent and never overwrites an operator's rows" do
    create(:ai_provider, name: "OpenAI", base_url: "https://api.openai.com/")
    OpenaiCatalog.provision!
    slug = OpenaiCatalog::MODELS.keys.first
    AiModel.find_by!(api_model_id: slug).update!(display_name: "custom")

    assert_no_difference([ "AiModel.count", "ModelPrice.count" ]) { OpenaiCatalog.provision! }
    assert_equal "custom", AiModel.find_by!(api_model_id: slug).display_name
  end
end
