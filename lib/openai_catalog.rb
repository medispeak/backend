# OpenAI-direct models beyond the ones db/seeds.rb creates inline, and their
# list prices. Shared by seeds and the provisioning data migration so the two
# cannot drift — the same reason OpenrouterCatalog exists.
#
# Direct is a different row from the OpenRouter one for the same model: a
# different provider, key, base_url and price table entry. Having both lets an
# operator move a function between them without editing anything else, and the
# adapter already sends the right output-budget parameter for each host
# (max_completion_tokens for api.openai.com, max_tokens elsewhere).
module OpenaiCatalog
  PROVIDER_NAME = "OpenAI".freeze

  # api_model_id => { display_name:, capabilities:, input_per_million:, output_per_million: }
  MODELS = {
    "gpt-5.6-luna" => {
      display_name: "GPT-5.6 Luna",
      capabilities: {
        "can_structure" => true, "supports_json_schema" => true,
        "supports_function_calling" => true,
        "supports_vision" => true, "supports_pdf" => true,
        "max_output_tokens" => 128_000
      },
      # OpenRouter lists this model at the same figures, which is its pass-through
      # of OpenAI's list price. Correct it in the admin if OpenAI's direct rate
      # differs — the price is a row, not code.
      input_per_million: 0.10,
      output_per_million: 0.60
    }
  }.freeze

  # Idempotent: creates only what is missing, never overwrites an operator's
  # rows. Returns the provider, or nil when it does not exist yet.
  def self.provision!(now: Time.current)
    provider = AiProvider.find_by(name: PROVIDER_NAME)
    return nil unless provider

    MODELS.each do |api_model_id, attrs|
      AiModel.find_or_create_by!(ai_provider: provider, api_model_id: api_model_id) do |m|
        m.display_name = attrs[:display_name]
        m.capabilities = attrs[:capabilities]
      end
      ModelPrice.find_or_create_by!(provider: PROVIDER_NAME, model: api_model_id) do |price|
        price.input_per_million = attrs[:input_per_million]
        price.output_per_million = attrs[:output_per_million]
        price.currency = "USD"
        price.effective_at = now
      end
    end

    provider
  end
end
