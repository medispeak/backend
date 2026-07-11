require "administrate/base_dashboard"

# Read-only admin view of a scribe session and ALL data associated with it:
# the transcript, the per-segment incremental transcripts, the storage audio
# chunks, every requested output (form/note/transcript results), and the
# metering/usage events. New/edit/destroy are disabled in the controller.
class ScribeSessionDashboard < Administrate::BaseDashboard
  ATTRIBUTE_TYPES = {
    id: Field::Number,
    account: Field::BelongsTo,
    user: Field::BelongsTo,
    api_token: Field::BelongsTo,
    status: Field::String,
    mode: Field::String,
    language: Field::String,
    transcript: Field::HasOne,
    scribe_outputs: Field::HasMany,
    transcript_segments: Field::HasMany,
    audio_chunks: Field::HasMany,
    usage_events: Field::HasMany,
    callback_url: Field::String,
    idempotency_key: Field::String,
    expires_at: Field::DateTime,
    error: Field::String.with_options(searchable: false),
    created_at: Field::DateTime,
    updated_at: Field::DateTime
  }.freeze

  COLLECTION_ATTRIBUTES = %i[
    id
    account
    user
    status
    mode
    language
    created_at
  ].freeze

  SHOW_PAGE_ATTRIBUTES = %i[
    id
    account
    user
    api_token
    status
    mode
    language
    transcript
    scribe_outputs
    transcript_segments
    audio_chunks
    usage_events
    callback_url
    idempotency_key
    expires_at
    error
    created_at
    updated_at
  ].freeze

  # Read-only resource: no form attributes.
  FORM_ATTRIBUTES = [].freeze

  COLLECTION_FILTERS = {
    processing: ->(resources) { resources.where(status: "processing") },
    completed: ->(resources) { resources.where(status: "completed") },
    failed: ->(resources) { resources.where(status: %w[failed partial]) }
  }.freeze

  def display_resource(scribe_session)
    "Session ##{scribe_session.id} (#{scribe_session.status})"
  end
end
