require "administrate/base_dashboard"

# Read-only admin view of one requested output of a scribe session (a form
# extraction, a note, or the transcript echo) and its structured result.
class ScribeOutputDashboard < Administrate::BaseDashboard
  ATTRIBUTE_TYPES = {
    id: Field::Number,
    scribe_session: Field::BelongsTo,
    output_type: Field::String,
    status: Field::String,
    page: Field::BelongsTo,
    template_ref: Field::String,
    result: Field::Text.with_options(searchable: false),
    result_errors: Field::Text.with_options(searchable: false),
    inline_fields: Field::Text.with_options(searchable: false),
    context: Field::Text.with_options(searchable: false),
    created_at: Field::DateTime,
    updated_at: Field::DateTime
  }.freeze

  COLLECTION_ATTRIBUTES = %i[
    id
    scribe_session
    output_type
    status
    created_at
  ].freeze

  SHOW_PAGE_ATTRIBUTES = %i[
    id
    scribe_session
    output_type
    status
    page
    template_ref
    result
    result_errors
    inline_fields
    context
    created_at
    updated_at
  ].freeze

  FORM_ATTRIBUTES = [].freeze

  COLLECTION_FILTERS = {}.freeze

  def display_resource(scribe_output)
    "Output ##{scribe_output.id} (#{scribe_output.output_type})"
  end
end
