require "test_helper"

class LlmConfigResolverTest < ActiveSupport::TestCase
  test "falls back to the ENV default when no assignment exists" do
    cfg = Llm::ConfigResolver.call(function: :structuring)
    assert_equal "gpt-4o-mini", cfg.api_model_id
    assert_equal :openai_compatible, cfg.provider_kind
  end

  test "uses a System assignment" do
    model = create(:ai_model, api_model_id: "sys-model")
    create(:model_assignment, scope_type: "System", scope_id: nil, function: "structuring", ai_model: model)

    cfg = Llm::ConfigResolver.call(function: :structuring)
    assert_equal "sys-model", cfg.api_model_id
  end

  test "Account assignment overrides System" do
    account = create(:account)
    create(:model_assignment, scope_type: "System", function: "structuring",
                              ai_model: create(:ai_model, api_model_id: "sys"))
    create(:model_assignment, scope_type: "Account", scope_id: account.id, function: "structuring",
                              ai_model: create(:ai_model, api_model_id: "acc"))

    cfg = Llm::ConfigResolver.call(function: :structuring, account: account)
    assert_equal "acc", cfg.api_model_id
  end

  test "Page assignment overrides Account and System" do
    account = create(:account)
    page = create(:page)
    create(:model_assignment, scope_type: "System", function: "structuring",
                              ai_model: create(:ai_model, api_model_id: "sys"))
    create(:model_assignment, scope_type: "Account", scope_id: account.id, function: "structuring",
                              ai_model: create(:ai_model, api_model_id: "acc"))
    create(:model_assignment, scope_type: "Page", scope_id: page.id, function: "structuring",
                              ai_model: create(:ai_model, api_model_id: "page"))

    cfg = Llm::ConfigResolver.call(function: :structuring, page: page, account: account)
    assert_equal "page", cfg.api_model_id
  end

  test "Template assignment overrides Account and System (but Page wins over Template)" do
    account = create(:account)
    template = create(:template)
    page = create(:page, template: template)
    create(:model_assignment, scope_type: "System", function: "structuring",
                              ai_model: create(:ai_model, api_model_id: "sys"))
    create(:model_assignment, scope_type: "Template", scope_id: template.id, function: "structuring",
                              ai_model: create(:ai_model, api_model_id: "tmpl"))

    cfg = Llm::ConfigResolver.call(function: :structuring, page: page, account: account)
    assert_equal "tmpl", cfg.api_model_id

    create(:model_assignment, scope_type: "Page", scope_id: page.id, function: "structuring",
                              ai_model: create(:ai_model, api_model_id: "page"))
    cfg2 = Llm::ConfigResolver.call(function: :structuring, page: page, account: account)
    assert_equal "page", cfg2.api_model_id
  end

  test "resolves provider details, capabilities, options, fallback, and decrypts the key" do
    provider = create(:ai_provider, api_key: "sk-xyz", base_url: "http://host:8000/", kind: "openai_compatible")
    primary = create(:ai_model, ai_provider: provider, api_model_id: "primary",
                                capabilities: { "can_transcribe" => true })
    fallback = create(:ai_model, api_model_id: "fb")
    create(:model_assignment, scope_type: "System", function: "asr", ai_model: primary,
                              fallback_ai_model: fallback,
                              options: { "language" => "hi", "asr_mode" => "translate" })

    cfg = Llm::ConfigResolver.call(function: :asr)

    assert_equal "primary", cfg.api_model_id
    assert_equal :openai_compatible, cfg.provider_kind
    assert_equal "http://host:8000/", cfg.base_url
    assert cfg.capability?(:can_transcribe)
    assert_equal "hi", cfg.options[:language]
    assert_equal :translate, cfg.asr_mode, "asr_mode resolves from the assignment options"
    assert_equal "sk-xyz", cfg.api_key, "api_key should decrypt via the lazy resolver"
    assert_equal "fb", cfg.fallback.api_model_id
  end

  test "api key is encrypted at rest" do
    provider = create(:ai_provider, api_key: "sk-plaintext-secret")
    raw = AiProvider.connection.select_value("SELECT api_key FROM ai_providers WHERE id = #{provider.id}")
    refute_includes raw.to_s, "sk-plaintext-secret"
    assert_equal "sk-plaintext-secret", AiProvider.find(provider.id).api_key
  end
end
