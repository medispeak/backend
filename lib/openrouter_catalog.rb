# The OpenRouter models we expose as selectable ASR / structuring options, and
# their list prices. One source of truth for db/seeds.rb and the provisioning
# data migration, so the two cannot drift.
#
# ASR rows go through OpenRouter's dedicated /api/v1/audio/transcriptions
# endpoint, which accepts OpenAI-style multipart requests — exactly what
# Llm::Adapters::OpenaiCompatible#transcribe already sends against the
# existing "OpenRouter" provider row (base_url https://openrouter.ai/api/).
# Caveats: transcribe only (no /audio/translations), ~60s upstream timeout and
# a 25 MB multipart cap — fine for 3s segments; give whole-file assignments a
# fallback model.
#
# Prices are the per-minute (audio) / per-million-token (text) list prices
# shown on openrouter.ai model pages on 2026-08-16. OpenRouter's models API
# reports STT prices in each provider's native unit (per second, minute or
# hour), so the per-minute figures below were normalized by hand from the
# unit displayed on each model page. Re-check when adding models.
module OpenrouterCatalog
  PROVIDER_NAME = "OpenRouter".freeze

  ASR_CAPABILITIES = { "accepts_audio" => true, "can_transcribe" => true }.freeze
  STRUCTURING_CAPABILITIES = {
    "can_structure" => true, "supports_json_schema" => true, "supports_function_calling" => true
  }.freeze

  # api_model_id => { display_name:, price_per_minute: }
  ASR_MODELS = {
    "openai/whisper-large-v3" => { display_name: "Whisper Large V3 (OpenRouter)", price_per_minute: 0.00045 },
    "openai/whisper-large-v3-turbo" => { display_name: "Whisper Large V3 Turbo (OpenRouter)", price_per_minute: 0.0002 },
    "nvidia/nemotron-3.5-asr-streaming-multilingual-0.6b" => { display_name: "NVIDIA Nemotron 3.5 ASR (OpenRouter)", price_per_minute: 0.0002 },
    "qwen/qwen3-asr-flash-2026-02-10" => { display_name: "Qwen3 ASR Flash (OpenRouter)", price_per_minute: 0.0021 },
    "x-ai/grok-stt-1.0" => { display_name: "Grok STT 1.0 (OpenRouter)", price_per_minute: 0.001667 },
    "deepgram/nova-3" => { display_name: "Deepgram Nova-3 (OpenRouter)", price_per_minute: 0.0043 },
    "google/chirp-3" => { display_name: "Google Chirp 3 (OpenRouter)", price_per_minute: 0.016 },
    "mistralai/voxtral-mini-transcribe" => { display_name: "Voxtral Mini Transcribe (OpenRouter)", price_per_minute: 0.003 },
    # Token-priced upstream ($1.25/M in, $5/M out); OpenAI's own per-minute estimate.
    "openai/gpt-4o-mini-transcribe" => { display_name: "GPT-4o mini Transcribe (OpenRouter)", price_per_minute: 0.003 }
  }.freeze

  # api_model_id => { display_name:, input_per_million:, output_per_million: }
  STRUCTURING_MODELS = {
    "openai/gpt-oss-120b" => { display_name: "gpt-oss-120b (OpenRouter)", input_per_million: 0.03, output_per_million: 0.17 },
    "x-ai/grok-4.20" => { display_name: "Grok 4.20 (OpenRouter)", input_per_million: 1.25, output_per_million: 2.50 },
    "x-ai/grok-4.6" => { display_name: "Grok 4.6 (OpenRouter)", input_per_million: 2.00, output_per_million: 6.00 },
    "google/gemini-3.1-flash-lite" => { display_name: "Gemini 3.1 Flash Lite (OpenRouter)", input_per_million: 0.25, output_per_million: 1.50 },
    "google/gemini-3.7-flash" => { display_name: "Gemini 3.7 Flash (OpenRouter)", input_per_million: 0.375, output_per_million: 1.875 },
    "nvidia/nemotron-3-super-120b-a12b" => { display_name: "Nemotron 3 Super 120B (OpenRouter)", input_per_million: 0.085, output_per_million: 0.40 },
    "nvidia/nemotron-3.5-lightning" => { display_name: "Nemotron 3.5 Lightning (OpenRouter)", input_per_million: 0.10, output_per_million: 0.25 }
  }.freeze

  # Idempotent: creates only what is missing and never overwrites an
  # operator's existing model or price rows. Returns the provider.
  def self.provision!(now: Time.current)
    provider = AiProvider.find_or_create_by!(name: PROVIDER_NAME) do |p|
      p.kind = "openai_compatible"
      p.base_url = "https://openrouter.ai/api/"
      p.api_key = ENV["OPENROUTER_API_KEY"].presence || "set-your-openrouter-api-key"
    end

    ASR_MODELS.each do |api_model_id, attrs|
      AiModel.find_or_create_by!(ai_provider: provider, api_model_id: api_model_id) do |m|
        m.display_name = attrs[:display_name]
        m.capabilities = ASR_CAPABILITIES
      end
      AudioModelPrice.find_or_create_by!(provider: PROVIDER_NAME, model: api_model_id) do |price|
        price.price_per_minute = attrs[:price_per_minute]
        price.currency = "USD"
        price.effective_at = now
      end
    end

    STRUCTURING_MODELS.each do |api_model_id, attrs|
      AiModel.find_or_create_by!(ai_provider: provider, api_model_id: api_model_id) do |m|
        m.display_name = attrs[:display_name]
        m.capabilities = STRUCTURING_CAPABILITIES
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
