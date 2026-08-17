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

  test "provision! creates every OCR model with vision capabilities, an output ceiling, and a token price" do
    provider = OpenrouterCatalog.provision!

    OpenrouterCatalog::OCR_MODELS.each do |slug, attrs|
      model = AiModel.find_by!(ai_provider: provider, api_model_id: slug)
      assert model.capability?(:supports_vision), slug
      assert model.capability?(:supports_pdf), slug
      # Some of these are structuring models too; that loop creates the shared
      # row first, so the vision keys have to be merged in rather than set.
      if OpenrouterCatalog::STRUCTURING_MODELS.key?(slug)
        assert model.capability?(:can_structure), "#{slug} lost its structuring capability"
      else
        assert_equal attrs[:display_name], model.display_name
      end

      # The adapter reads this to decide how far it may let OcrStage's
      # page-sized budget through; without it every long report is clamped to
      # the adapter's conservative default.
      ceiling = model.capabilities["max_output_tokens"]
      assert_equal attrs[:max_output_tokens], ceiling, slug
      assert_operator ceiling, :>=, Scribe::OcrStage::MAX_MAX_TOKENS,
                      "#{slug} cannot deliver a full-cap document"

      price = ModelPrice.current.find_by(provider: "OpenRouter", model: slug)
      assert price, "token price for #{slug}"
      assert_operator price.input_per_million, :>, 0
      # OCR bills on tokens here; a DocumentModelPrice row would be charged ON
      # TOP of that by PriceBook, i.e. billed twice for one call.
      assert_nil DocumentModelPrice.current.find_by(provider: "OpenRouter", model: slug),
                 "#{slug} must not carry a per-page price as well"
    end
  end

  # A model listed in both STRUCTURING_MODELS and OCR_MODELS is ONE AiModel row.
  # The structuring loop creates it first, so the vision keys have to be merged
  # in afterwards or the row silently serves only structuring.
  test "a model in both catalogs ends up serving both functions" do
    provider = OpenrouterCatalog.provision!
    dual = OpenrouterCatalog::OCR_MODELS.keys & OpenrouterCatalog::STRUCTURING_MODELS.keys
    assert dual.any?, "expected at least one model listed under both functions"

    dual.each do |slug|
      model = AiModel.find_by!(ai_provider: provider, api_model_id: slug)
      assert model.capability?(:can_structure), slug
      assert model.capability?(:supports_vision), slug
      assert model.capability?(:supports_pdf), slug
      assert_equal OpenrouterCatalog::OCR_MODELS[slug][:max_output_tokens],
                   model.capabilities["max_output_tokens"], slug
      # One price row, not one per catalog.
      assert_equal 1, ModelPrice.where(provider: "OpenRouter", model: slug).count, slug
    end
  end

  test "assign_default_ocr! points the System default at the chosen model with a different-vendor fallback" do
    OpenrouterCatalog.provision!
    assignment = OpenrouterCatalog.assign_default_ocr!

    assert_equal "System", assignment.scope_type
    assert_nil assignment.scope_id
    assert_equal OpenrouterCatalog::DEFAULT_OCR_MODEL, assignment.ai_model.api_model_id
    assert_equal OpenrouterCatalog::DEFAULT_OCR_FALLBACK_MODEL, assignment.fallback_ai_model.api_model_id
    assert_not_equal assignment.ai_model.api_model_id.split("/").first,
                     assignment.fallback_ai_model.api_model_id.split("/").first,
                     "the fallback must not share the primary's vendor"

    # What a document session actually resolves to, fallback included.
    cfg = Llm::ConfigResolver.call(function: :ocr)
    assert_equal OpenrouterCatalog::DEFAULT_OCR_MODEL, cfg.api_model_id
    assert_equal "https://openrouter.ai/api/", cfg.base_url
    assert_equal OpenrouterCatalog::DEFAULT_OCR_FALLBACK_MODEL, cfg.fallback.api_model_id
    assert_equal OpenrouterCatalog::OCR_MODELS[OpenrouterCatalog::DEFAULT_OCR_MODEL][:max_output_tokens],
                 cfg.capabilities[:max_output_tokens]
  end

  test "assign_default_ocr! leaves an operator's existing OCR choice alone" do
    provider = OpenrouterCatalog.provision!
    chosen = AiModel.find_by!(ai_provider: provider, api_model_id: "anthropic/claude-haiku-4.5")
    create(:model_assignment, scope_type: "System", scope_id: nil, function: "ocr", ai_model: chosen)

    assert_no_difference("ModelAssignment.count") { OpenrouterCatalog.assign_default_ocr! }
    assert_equal "anthropic/claude-haiku-4.5", Llm::ConfigResolver.call(function: :ocr).api_model_id
  end

  test "the OCR default is priced end to end for a real document run" do
    OpenrouterCatalog.provision!
    OpenrouterCatalog.assign_default_ocr!
    slug = OpenrouterCatalog::DEFAULT_OCR_MODEL
    attrs = OpenrouterCatalog::OCR_MODELS[slug]

    # A 12-page report: ~20k input tokens of image, ~9k of extracted markdown.
    pricing = Metering::PriceBook.cost(function: :ocr, provider: "OpenRouter", model: slug,
                                       usage: Llm::Usage.new(input_tokens: 20_000, output_tokens: 9_000, pages: 12))
    expected = (20_000 / 1_000_000.0 * attrs[:input_per_million]) +
               (9_000 / 1_000_000.0 * attrs[:output_per_million])
    assert_in_delta expected, pricing[:cost], 1e-6
    assert_operator pricing[:cost], :>, 0, "a metered OCR run must not price at zero"
    assert_nil pricing[:unit_price_page], "no per-page component is configured for a token-billed model"
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
