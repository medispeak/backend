require "test_helper"

class OpenrouterCatalogTest < ActiveSupport::TestCase
  test "provision! creates the provider, every model with the right capabilities, and a price per model" do
    provider = OpenrouterCatalog.provision!

    assert_equal "openai_compatible", provider.kind
    assert_equal "https://openrouter.ai/api/", provider.base_url

    OpenrouterCatalog::ASR_MODELS.each do |slug, attrs|
      model = AiModel.find_by!(ai_provider: provider, api_model_id: slug)
      assert model.capability?(:can_transcribe), slug
      assert_not model.capability?(:can_structure), slug
      assert_equal attrs[:display_name], model.display_name
      price = AudioModelPrice.current.find_by(provider: "OpenRouter", model: slug)
      assert price, "audio price for #{slug}"
      assert_operator price.price_per_minute, :>, 0
    end

    OpenrouterCatalog::STRUCTURING_MODELS.each do |slug, attrs|
      model = AiModel.find_by!(ai_provider: provider, api_model_id: slug)
      assert model.capability?(:can_structure), slug
      assert model.capability?(:supports_json_schema), slug
      assert_not model.capability?(:can_transcribe), slug
      assert_equal attrs[:display_name], model.display_name
      price = ModelPrice.current.find_by(provider: "OpenRouter", model: slug)
      assert price, "token price for #{slug}"
      assert_operator price.input_per_million, :>, 0
    end
  end

  test "provision! is idempotent and never overwrites existing rows" do
    provider = OpenrouterCatalog.provision!
    slug = OpenrouterCatalog::ASR_MODELS.keys.first
    AiModel.find_by!(ai_provider: provider, api_model_id: slug).update!(display_name: "custom name")
    AudioModelPrice.find_by!(provider: "OpenRouter", model: slug).update!(price_per_minute: 9.99)

    assert_no_difference([ "AiModel.count", "AudioModelPrice.count", "ModelPrice.count", "AiProvider.count" ]) do
      OpenrouterCatalog.provision!
    end
    assert_equal "custom name", AiModel.find_by!(ai_provider: provider, api_model_id: slug).display_name
    assert_equal 9.99, AudioModelPrice.find_by!(provider: "OpenRouter", model: slug).price_per_minute.to_f
  end

  test "resolver + price book work end to end for an OpenRouter STT model" do
    provider = OpenrouterCatalog.provision!
    model = AiModel.find_by!(ai_provider: provider, api_model_id: "openai/whisper-large-v3")
    create(:model_assignment, scope_type: "System", scope_id: nil, function: "asr", ai_model: model)

    cfg = Llm::ConfigResolver.call(function: :asr)
    assert_equal "openai/whisper-large-v3", cfg.api_model_id
    assert_equal :openai_compatible, cfg.provider_kind
    assert_equal "https://openrouter.ai/api/", cfg.base_url

    pricing = Metering::PriceBook.cost(function: :asr, provider: "OpenRouter", model: "openai/whisper-large-v3",
                                       usage: Llm::Usage.new(audio_seconds: 120))
    assert_in_delta 0.0009, pricing[:cost], 1e-6
  end
end
