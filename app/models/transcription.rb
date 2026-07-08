class Transcription < ApplicationRecord
  belongs_to :user
  belongs_to :page
  has_many :form_fields, through: :page

  has_one_attached :audio_file

  # Audio upload allowlist + ceiling (see plan 014). The v1 controller rejects
  # bad uploads before persisting; this attachment validation is defense-in-depth.
  ALLOWED_AUDIO_TYPES = %w[
    audio/mpeg audio/mp4 audio/wav audio/x-wav audio/webm audio/ogg audio/m4a audio/aac
  ].freeze
  MAX_AUDIO_BYTES = 25.megabytes

  validates :audio_file,
            content_type: ALLOWED_AUDIO_TYPES,
            size: { less_than_or_equal_to: MAX_AUDIO_BYTES }

  enum :status, { pending: "pending", transcribed: "transcribed", completion_generated: "completion_generated", failed: "failed" }
end
