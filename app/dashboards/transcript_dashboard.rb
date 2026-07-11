require "administrate/base_dashboard"

# Read-only admin view of the final persisted transcript for a session.
class TranscriptDashboard < Administrate::BaseDashboard
  ATTRIBUTE_TYPES = {
    id: Field::Number,
    scribe_session: Field::BelongsTo,
    text: Field::Text,
    language: Field::String,
    duration_seconds: Field::Number.with_options(decimals: 3),
    provider: Field::String,
    model: Field::String,
    segments: Field::Text.with_options(searchable: false),
    words: Field::Text.with_options(searchable: false),
    speakers: Field::Text.with_options(searchable: false),
    created_at: Field::DateTime,
    updated_at: Field::DateTime
  }.freeze

  COLLECTION_ATTRIBUTES = %i[
    id
    scribe_session
    language
    provider
    model
    duration_seconds
    created_at
  ].freeze

  SHOW_PAGE_ATTRIBUTES = %i[
    id
    scribe_session
    text
    language
    duration_seconds
    provider
    model
    segments
    words
    speakers
    created_at
    updated_at
  ].freeze

  FORM_ATTRIBUTES = [].freeze

  COLLECTION_FILTERS = {}.freeze

  def display_resource(transcript)
    "Transcript ##{transcript.id}"
  end
end
