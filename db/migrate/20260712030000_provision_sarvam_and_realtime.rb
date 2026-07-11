# Provisions the Sarvam ASR provider (Indic STT + translate/codemix) and the
# realtime default on environments whose DB already exists (so db:seed does not
# re-run). Idempotent: only creates missing rows and backfills the Sarvam key
# from ENV. Never overwrites an operator's existing config.
class ProvisionSarvamAndRealtime < ActiveRecord::Migration[8.0]
  def up
    sarvam = AiProvider.find_or_create_by!(name: "Sarvam") do |p|
      p.kind = "sarvam"
      p.base_url = "https://api.sarvam.ai"
      p.api_key = ENV["SARVAM_API_KEY"] if ENV["SARVAM_API_KEY"].present?
    end

    # Backfill the key if the provider row predates the secret being set.
    if ENV["SARVAM_API_KEY"].present? && sarvam.api_key.blank?
      sarvam.update!(api_key: ENV["SARVAM_API_KEY"])
    end

    AiModel.find_or_create_by!(ai_provider: sarvam, api_model_id: "saaras:v3") do |m|
      m.display_name = "Sarvam Saaras v3 (Indic ASR + translate)"
      m.capabilities = { "accepts_audio" => true, "can_transcribe" => true }
    end

    price = AudioModelPrice.find_or_initialize_by(provider: "Sarvam", model: "saaras:v3")
    if price.new_record?
      price.update!(price_per_minute: 0.006, currency: "USD", effective_at: Time.current)
    end

    # Realtime default: OpenAI gpt-4o-transcribe. Optional — ConfigResolver falls
    # back to the ENV-based default for :realtime if this assignment is absent —
    # but seeding it lets operators override realtime per account/page.
    openai = AiProvider.find_by(name: "OpenAI")
    transcribe = openai && AiModel.find_by(ai_provider: openai, api_model_id: "gpt-4o-transcribe")
    if transcribe && !ModelAssignment.exists?(scope_type: "System", scope_id: nil, function: "realtime")
      ModelAssignment.create!(scope_type: "System", scope_id: nil, function: "realtime", ai_model: transcribe)
    end
  end

  def down
    # Configuration rows; leave them in place.
  end
end
