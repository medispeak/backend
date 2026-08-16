module Bench
  # Builds the same Llm::Config the resolver would for an AiModel, without a
  # ModelAssignment — the bench runs models side by side, not "the assigned
  # one". Keys come from the provider row; an ENV override lets you bench a
  # provider whose local row still holds the seed placeholder:
  #   OPENROUTER_API_KEY / OPENAI_ACCESS_TOKEN / ANTHROPIC_API_KEY / SARVAM_API_KEY
  module ModelConfig
    ENV_KEYS = {
      "OpenRouter" => "OPENROUTER_API_KEY",
      "OpenAI" => "OPENAI_ACCESS_TOKEN",
      "Anthropic" => "ANTHROPIC_API_KEY",
      "Sarvam" => "SARVAM_API_KEY"
    }.freeze

    PLACEHOLDER = /\Aset-your-|\Anot-needed\z/

    def self.for(model, options: {})
      provider = model.ai_provider
      Llm::Config.new(
        provider_kind: provider.kind,
        provider_name: provider.name,
        api_model_id: model.api_model_id,
        base_url: provider.base_url,
        organization_id: provider.organization_id,
        request_timeout: provider.request_timeout || 120,
        capabilities: model.capabilities,
        options: (options || {}).transform_keys(&:to_sym),
        api_key: api_key_for(provider)
      )
    end

    def self.api_key_for(provider)
      env_key = ENV_KEYS[provider.name]
      override = env_key && ENV[env_key].presence
      return override if override

      provider.api_key
    end

    # True when the provider has no usable key (bench skips it with a note).
    def self.missing_key?(provider)
      key = api_key_for(provider).to_s
      key.empty? || key.match?(PLACEHOLDER)
    end
  end
end
