require "administrate/base_dashboard"

class UsageEventDashboard < Administrate::BaseDashboard
  # ATTRIBUTE_TYPES
  # a hash that describes the type of each of the model's fields.
  #
  # Each different type represents an Administrate::Field object,
  # which determines how the attribute is displayed
  # on pages throughout the dashboard.
  #
  # This is a READ-ONLY metering ledger. The controller disables
  # new/edit/destroy (see Admin::UsageEventsController#valid_action?).
  ATTRIBUTE_TYPES = {
    id: Field::Number,
    account: Field::BelongsTo,
    api_token: Field::BelongsTo,
    function: Field::String,
    provider: Field::String,
    model: Field::String,
    input_tokens: Field::Number,
    output_tokens: Field::Number,
    total_tokens: Field::Number,
    audio_seconds: Field::Number.with_options(decimals: 3),
    cost: Field::Number.with_options(decimals: 6),
    currency: Field::String,
    status: Field::String,
    latency_ms: Field::Number,
    created_at: Field::DateTime,
    updated_at: Field::DateTime
  }.freeze

  # COLLECTION_ATTRIBUTES
  # an array of attributes that will be displayed on the model's index page.
  #
  # By default, it's limited to four items to reduce clutter on index pages.
  # Feel free to add, remove, or rearrange items.
  COLLECTION_ATTRIBUTES = %i[
    function
    provider
    model
    total_tokens
    audio_seconds
    cost
    status
    created_at
  ].freeze

  # SHOW_PAGE_ATTRIBUTES
  # an array of attributes that will be displayed on the model's show page.
  SHOW_PAGE_ATTRIBUTES = %i[
    id
    account
    api_token
    function
    provider
    model
    input_tokens
    output_tokens
    total_tokens
    audio_seconds
    cost
    currency
    status
    latency_ms
    created_at
    updated_at
  ].freeze

  # FORM_ATTRIBUTES
  # Read-only resource: no form attributes (new/edit are disabled in the
  # controller via valid_action?).
  FORM_ATTRIBUTES = [].freeze

  # COLLECTION_FILTERS
  # a hash that defines filters that can be used while searching via the search
  # field of the dashboard.
  COLLECTION_FILTERS = {
    finalized: ->(resources) { resources.where(status: "finalized") },
    failed: ->(resources) { resources.where(status: "failed") }
  }.freeze

  # Overwrite this method to customize how usage events are displayed
  # across all pages of the admin dashboard.
  def display_resource(usage_event)
    "Usage ##{usage_event.id} (#{usage_event.function})"
  end
end
