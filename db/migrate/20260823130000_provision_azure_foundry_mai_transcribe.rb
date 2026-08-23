# Provisions the Azure Foundry provider and Microsoft's MAI-Transcribe 1.5 ASR
# model on environments whose DB already exists (so db:seed does not re-run).
# Idempotent: only creates missing rows and backfills base_url/api_key from ENV.
# Never overwrites an operator's existing config.
class ProvisionAzureFoundryMaiTranscribe < ActiveRecord::Migration[8.1]
  # base_url is per-resource (unlike Sarvam/OpenAI there is no universal host),
  # so it comes from ENV, with a placeholder so the row shows in the admin UI.
  # RFC 2606 .invalid: a *.cognitiveservices.azure.com placeholder would be a
  # claimable subdomain — assigning the model before fixing the URL would send
  # the key + patient audio to whoever registered it. .invalid never resolves.
  PLACEHOLDER_BASE_URL = "https://azure-foundry.invalid".freeze

  def up
    provider = AiProvider.find_or_create_by!(name: "Azure Foundry") do |p|
      p.kind = "azure_foundry"
      p.base_url = ENV["AZURE_FOUNDRY_BASE_URL"].presence || PLACEHOLDER_BASE_URL
      p.api_key = ENV["AZURE_FOUNDRY_API_KEY"] if ENV["AZURE_FOUNDRY_API_KEY"].present?
    end

    # Backfill when the provider row predates the secrets being set.
    if ENV["AZURE_FOUNDRY_API_KEY"].present? && provider.api_key.blank?
      provider.update!(api_key: ENV["AZURE_FOUNDRY_API_KEY"])
    end
    if ENV["AZURE_FOUNDRY_BASE_URL"].present? && provider.base_url == PLACEHOLDER_BASE_URL
      provider.update!(base_url: ENV["AZURE_FOUNDRY_BASE_URL"])
    end

    AiModel.find_or_create_by!(ai_provider: provider, api_model_id: "mai-transcribe-1.5") do |m|
      m.display_name = "MAI-Transcribe 1.5 (Azure Foundry)"
      m.capabilities = { "accepts_audio" => true, "can_transcribe" => true }
    end

    # $0.36 per hour of audio -> per-minute.
    price = AudioModelPrice.find_or_initialize_by(provider: "Azure Foundry", model: "mai-transcribe-1.5")
    if price.new_record?
      price.update!(price_per_minute: 0.006, currency: "USD", effective_at: Time.current)
    end
  end

  def down
    # Configuration rows; leave them in place.
  end
end
