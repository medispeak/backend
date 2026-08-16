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
  ].freeze

  def capability?(name)
    !!capabilities[name.to_s] || !!capabilities[name.to_sym]
  end
end
