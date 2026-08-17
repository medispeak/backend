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
  # Base OCR capabilities; each model adds its own "max_output_tokens" below.
  OCR_CAPABILITIES = { "supports_vision" => true, "supports_pdf" => true }.freeze

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
    "nvidia/nemotron-3.5-lightning" => { display_name: "Nemotron 3.5 Lightning (OpenRouter)", input_per_million: 0.10, output_per_million: 0.25 },
    # Also OCR models (see OCR_MODELS): one row serves both functions, and
    # provision! merges the vision capabilities in after this loop creates it.
    "openai/gpt-5.6-luna" => { display_name: "GPT-5.6 Luna (OpenRouter)", input_per_million: 0.10, output_per_million: 0.60 },
    "google/gemini-3.6-flash" => { display_name: "Gemini 3.6 Flash (OpenRouter)", input_per_million: 0.75, output_per_million: 3.75 }
  }.freeze

  # Vision models for the document (OCR) modality.
  #
  # Selection criteria, in order:
  #   1. Accepts BOTH image and file input. Llm::Adapters::OpenaiCompatible#ocr
  #      sends a PDF as OpenRouter's `type: "file"` part and a photo as
  #      `image_url`, so a model that takes only images cannot serve a PDF
  #      upload at all. Verified against the live /api/v1/models catalogue.
  #   2. A large output budget. OcrStage asks for 2000 tokens per page (up to
  #      MAX_MAX_TOKENS = 32k), and Llm::Adapter clamps that to the model's
  #      ceiling — so a model with a small ceiling silently truncates a long
  #      report into a fallback attempt. Every model here clears 32k, which is
  #      why max_output_tokens is recorded on the row: without it the adapter
  #      assumes its conservative default (16,384) and a 20-page report gets
  #      clamped for no reason.
  #   3. Vendor diversity, so the fallback is genuinely independent of the
  #      primary rather than the same weights behind a different name.
  #
  # `max_tokens` (not `max_completion_tokens`) is what OpenRouter wants, which
  # is what the adapter sends for any non-api.openai.com host. Confirmed present
  # in each model's supported_parameters.
  #
  # api_model_id => { display_name:, input_per_million:, output_per_million:, max_output_tokens: }
  OCR_MODELS = {
    # The default (see the assignment in the provisioning migration). Google's
    # current flagship Flash — `google/gemini-flash-latest` resolves to this
    # same price point — and the Flash line is the workhorse for dense document
    # extraction: 1M context, strong on tables, an order of magnitude cheaper
    # than the Pro tier. Already trusted here for structuring.
    "google/gemini-3.7-flash" => {
      display_name: "Gemini 3.7 Flash (OpenRouter)",
      input_per_million: 0.375, output_per_million: 1.875, max_output_tokens: 65_536
    },
    # The fallback: a different vendor, so a Google outage or refusal is
    # answered by something that does not share its failure mode. Cheaper in,
    # dearer out, and the largest output budget of the four.
    "openai/gpt-5-mini" => {
      display_name: "GPT-5 Mini (OpenRouter)",
      input_per_million: 0.25, output_per_million: 2.00, max_output_tokens: 128_000
    },
    # Cheapest of the four: for accounts running high volume on legible,
    # typeset reports where the Flash tier is more model than the job needs.
    "google/gemini-3.1-flash-lite" => {
      display_name: "Gemini 3.1 Flash Lite (OpenRouter)",
      input_per_million: 0.25, output_per_million: 1.50, max_output_tokens: 65_536
    },
    # The accuracy option, and a third vendor: worth the ~2.7x input price on
    # handwriting and poor phone photographs.
    "anthropic/claude-haiku-4.5" => {
      display_name: "Claude Haiku 4.5 (OpenRouter)",
      input_per_million: 1.00, output_per_million: 5.00, max_output_tokens: 64_000
    },
    # Also in STRUCTURING_MODELS — one AiModel row serves both functions.
    "openai/gpt-5.6-luna" => {
      display_name: "GPT-5.6 Luna (OpenRouter)",
      input_per_million: 0.10, output_per_million: 0.60, max_output_tokens: 128_000
    },
    "google/gemini-3.6-flash" => {
      display_name: "Gemini 3.6 Flash (OpenRouter)",
      input_per_million: 0.75, output_per_million: 3.75, max_output_tokens: 65_536
    }
  }.freeze

  # The System-scope OCR default and its fallback. Keys into OCR_MODELS.
  DEFAULT_OCR_MODEL = "google/gemini-3.7-flash".freeze
  DEFAULT_OCR_FALLBACK_MODEL = "openai/gpt-5-mini".freeze

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

    OCR_MODELS.each do |api_model_id, attrs|
      model = AiModel.find_or_create_by!(ai_provider: provider, api_model_id: api_model_id) do |m|
        m.display_name = attrs[:display_name]
        m.capabilities = OCR_CAPABILITIES.merge("max_output_tokens" => attrs[:max_output_tokens])
      end
      # One AiModel row per (provider, api_model_id), and some of these models
      # are ALSO in STRUCTURING_MODELS — that loop runs first and creates the
      # row with structuring capabilities only, so the block above never runs
      # and the vision keys would be missing. The same is true of any row an
      # operator created by hand. Fill in only the keys that are ABSENT: a
      # model that can structure can also read a document, and adding a
      # capability it demonstrably has is not overwriting anyone's choice —
      # whereas leaving max_output_tokens unset makes the adapter fall back to
      # its conservative ceiling and clamp every long report.
      desired = OCR_CAPABILITIES.merge("max_output_tokens" => attrs[:max_output_tokens])
      missing = desired.reject { |key, _| model.capabilities.key?(key) }
      model.update!(capabilities: model.capabilities.merge(missing)) if missing.any?
      # Token prices only. Vision providers bill OCR by tokens (the image is
      # charged as input tokens), and PriceBook adds a DocumentModelPrice
      # per-page component ON TOP of the token cost when a row exists — so
      # writing one here would bill these models twice for the same call.
      ModelPrice.find_or_create_by!(provider: PROVIDER_NAME, model: api_model_id) do |price|
        price.input_per_million = attrs[:input_per_million]
        price.output_per_million = attrs[:output_per_million]
        price.currency = "USD"
        price.effective_at = now
      end
    end

    provider
  end

  # Points the System-scope OCR default at DEFAULT_OCR_MODEL, with a
  # different-vendor fallback. Separate from #provision! because it changes a
  # DEFAULT rather than adding a selectable option: it creates the assignment
  # only when the function has none, so an operator who has already chosen an
  # OCR model keeps it. Returns the assignment, or nil if the models are absent.
  def self.assign_default_ocr!
    provider = AiProvider.find_by(name: PROVIDER_NAME)
    return nil unless provider

    model = AiModel.find_by(ai_provider: provider, api_model_id: DEFAULT_OCR_MODEL)
    fallback = AiModel.find_by(ai_provider: provider, api_model_id: DEFAULT_OCR_FALLBACK_MODEL)
    return nil unless model

    ModelAssignment.find_or_create_by!(scope_type: "System", scope_id: nil, function: "ocr") do |a|
      a.ai_model = model
      a.fallback_ai_model = fallback
    end
  end
end
