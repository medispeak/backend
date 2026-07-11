require "administrate/base_dashboard"

# Read-only admin view of one incremental transcription segment: the short
# standalone clip transcribed on arrival during recording, and its text.
class ScribeTranscriptSegmentDashboard < Administrate::BaseDashboard
  ATTRIBUTE_TYPES = {
    id: Field::Number,
    scribe_session: Field::BelongsTo,
    seq: Field::Number,
    status: Field::String,
    text: Field::Text,
    language: Field::String,
    provider: Field::String,
    model: Field::String,
    content_type: Field::String,
    duration_seconds: Field::Number.with_options(decimals: 3),
    transcribed_at: Field::DateTime,
    created_at: Field::DateTime,
    updated_at: Field::DateTime
  }.freeze

  COLLECTION_ATTRIBUTES = %i[
    id
    scribe_session
    seq
    status
    text
    duration_seconds
  ].freeze

  SHOW_PAGE_ATTRIBUTES = %i[
    id
    scribe_session
    seq
    status
    text
    language
    provider
    model
    content_type
    duration_seconds
    transcribed_at
    created_at
    updated_at
  ].freeze

  FORM_ATTRIBUTES = [].freeze

  COLLECTION_FILTERS = {
    done: ->(resources) { resources.where(status: "done") },
    failed: ->(resources) { resources.where(status: "failed") }
  }.freeze

  def display_resource(segment)
    "Segment ##{segment.seq}"
  end
end
