require "administrate/base_dashboard"

class AiProviderDashboard < Administrate::BaseDashboard
  # ATTRIBUTE_TYPES
  # a hash that describes the type of each of the model's fields.
  #
  # Each different type represents an Administrate::Field object,
  # which determines how the attribute is displayed
  # on pages throughout the dashboard.
  #
  # SECURITY: api_key is Active Record ENCRYPTED. It is kept OFF the index/show
  # pages (COLLECTION/SHOW) so the decrypted secret is never displayed, and is
  # rendered as a masked password input on the form so it can be set/rotated.
  ATTRIBUTE_TYPES = {
    id: Field::Number,
    name: Field::String,
    kind: Field::Select.with_options(
      collection: AiProvider::KINDS,
      searchable: false
    ),
    base_url: Field::String,
    api_key: Field::Password,
    organization_id: Field::String,
    request_timeout: Field::Number,
    active: Field::Boolean,
    ai_models: Field::HasMany,
    created_at: Field::DateTime,
    updated_at: Field::DateTime
  }.freeze

  # COLLECTION_ATTRIBUTES
  # an array of attributes that will be displayed on the model's index page.
  #
  # By default, it's limited to four items to reduce clutter on index pages.
  # Feel free to add, remove, or rearrange items.
  COLLECTION_ATTRIBUTES = %i[
    name
    kind
    base_url
    active
  ].freeze

  # SHOW_PAGE_ATTRIBUTES
  # an array of attributes that will be displayed on the model's show page.
  # api_key is deliberately omitted so the decrypted secret is never displayed.
  SHOW_PAGE_ATTRIBUTES = %i[
    id
    name
    kind
    base_url
    organization_id
    request_timeout
    active
    ai_models
    created_at
    updated_at
  ].freeze

  # FORM_ATTRIBUTES
  # an array of attributes that will be displayed
  # on the model's form (`new` and `edit`) pages.
  # api_key lives ONLY here so it is settable/rotatable. Leaving it blank on
  # edit submits an empty string; set it only when you intend to change it.
  FORM_ATTRIBUTES = %i[
    name
    kind
    base_url
    organization_id
    request_timeout
    active
    api_key
  ].freeze

  # COLLECTION_FILTERS
  # a hash that defines filters that can be used while searching via the search
  # field of the dashboard.
  COLLECTION_FILTERS = {
    active: ->(resources) { resources.where(active: true) }
  }.freeze

  # Overwrite this method to customize how ai providers are displayed
  # across all pages of the admin dashboard.
  def display_resource(ai_provider)
    "#{ai_provider.name} (#{ai_provider.kind})"
  end
end
