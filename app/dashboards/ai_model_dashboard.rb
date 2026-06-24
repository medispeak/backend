require "administrate/base_dashboard"

class AiModelDashboard < Administrate::BaseDashboard
  # ATTRIBUTE_TYPES
  # a hash that describes the type of each of the model's fields.
  #
  # Each different type represents an Administrate::Field object,
  # which determines how the attribute is displayed
  # on pages throughout the dashboard.
  #
  # capabilities is a JSON blob of booleans (accepts_audio, can_transcribe,
  # can_structure, supports_json_schema, supports_function_calling,
  # native_diarization). Edit it as JSON in the form, e.g.
  #   {"accepts_audio": true, "can_transcribe": true}
  ATTRIBUTE_TYPES = {
    id: Field::Number,
    ai_provider: Field::BelongsTo,
    api_model_id: Field::String,
    display_name: Field::String,
    capabilities: Field::Text,
    active: Field::Boolean,
    created_at: Field::DateTime,
    updated_at: Field::DateTime
  }.freeze

  # COLLECTION_ATTRIBUTES
  # an array of attributes that will be displayed on the model's index page.
  #
  # By default, it's limited to four items to reduce clutter on index pages.
  # Feel free to add, remove, or rearrange items.
  COLLECTION_ATTRIBUTES = %i[
    display_name
    ai_provider
    api_model_id
    active
  ].freeze

  # SHOW_PAGE_ATTRIBUTES
  # an array of attributes that will be displayed on the model's show page.
  SHOW_PAGE_ATTRIBUTES = %i[
    id
    ai_provider
    api_model_id
    display_name
    capabilities
    active
    created_at
    updated_at
  ].freeze

  # FORM_ATTRIBUTES
  # an array of attributes that will be displayed
  # on the model's form (`new` and `edit`) pages.
  FORM_ATTRIBUTES = %i[
    ai_provider
    api_model_id
    display_name
    capabilities
    active
  ].freeze

  # COLLECTION_FILTERS
  # a hash that defines filters that can be used while searching via the search
  # field of the dashboard.
  COLLECTION_FILTERS = {
    active: ->(resources) { resources.where(active: true) }
  }.freeze

  # Overwrite this method to customize how ai models are displayed
  # across all pages of the admin dashboard.
  def display_resource(ai_model)
    ai_model.display_name.presence || ai_model.api_model_id
  end
end
