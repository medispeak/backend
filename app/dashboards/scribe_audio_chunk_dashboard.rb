require "administrate/base_dashboard"

# Read-only admin view of one storage audio chunk (a fragment of the continuous
# recording, reassembled at commit into the session's playable audio blob).
class ScribeAudioChunkDashboard < Administrate::BaseDashboard
  ATTRIBUTE_TYPES = {
    id: Field::Number,
    scribe_session: Field::BelongsTo,
    seq: Field::Number,
    final: Field::Boolean,
    content_type: Field::String,
    created_at: Field::DateTime,
    updated_at: Field::DateTime
  }.freeze

  COLLECTION_ATTRIBUTES = %i[
    id
    scribe_session
    seq
    final
    content_type
    created_at
  ].freeze

  SHOW_PAGE_ATTRIBUTES = %i[
    id
    scribe_session
    seq
    final
    content_type
    created_at
    updated_at
  ].freeze

  FORM_ATTRIBUTES = [].freeze

  COLLECTION_FILTERS = {}.freeze

  def display_resource(chunk)
    "Chunk ##{chunk.seq}"
  end
end
