class AiModel < ApplicationRecord
  include JsonObjectColumns

  belongs_to :ai_provider

  validates :api_model_id, presence: true

  # Edited as JSON text in the admin UI; see JsonObjectColumns.
  json_object_columns :capabilities

  scope :active, -> { where(active: true) }

  CAPABILITIES = %i[
    accepts_audio can_transcribe can_structure
    supports_json_schema supports_function_calling native_diarization
    supports_vision supports_pdf
  ].freeze

  # The MINIMUM capability set a model needs to serve each assignment function.
  # Deliberately narrower than what Llm::DefaultConfigProvider stamps on a
  # model: requiring structuring's full set would hide claude-3-5-haiku, which
  # structures without supports_json_schema.
  FUNCTION_CAPABILITIES = {
    "asr" => %w[accepts_audio can_transcribe],
    "structuring" => %w[can_structure],
    "ocr" => %w[supports_vision]
  }.freeze

  # Models that can serve `function`. jsonb containment, so it is one indexable
  # predicate rather than a scan in Ruby.
  scope :for_function, ->(function) {
    required = FUNCTION_CAPABILITIES[function.to_s]
    next none if required.blank?

    required.reduce(all) do |scope, capability|
      scope.where("capabilities @> ?", { capability => true }.to_json)
    end
  }

  def capability?(name)
    !!capabilities[name.to_s] || !!capabilities[name.to_sym]
  end

  # The functions this model can be assigned to, e.g. ["structuring", "ocr"].
  def functions
    FUNCTION_CAPABILITIES.keys.select { |function| serves?(function) }
  end

  # Display form for the admin list. "—" rather than an empty cell, so a model
  # nothing can use is visibly that rather than looking like a rendering gap.
  def functions_label
    functions.presence&.join(", ") || "—"
  end

  def serves?(function)
    Array(FUNCTION_CAPABILITIES[function.to_s]).present? &&
      FUNCTION_CAPABILITIES[function.to_s].all? { |capability| capability?(capability) }
  end
end
