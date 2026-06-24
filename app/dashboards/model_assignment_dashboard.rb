require "administrate/base_dashboard"

class ModelAssignmentDashboard < Administrate::BaseDashboard
  # ATTRIBUTE_TYPES
  # a hash that describes the type of each of the model's fields.
  #
  # Each different type represents an Administrate::Field object,
  # which determines how the attribute is displayed
  # on pages throughout the dashboard.
  #
  # Resolution order is Page -> Account -> System. scope_id holds the Page or
  # Account id for those scopes and MUST be blank for the System scope.
  ATTRIBUTE_TYPES = {
    id: Field::Number,
    scope_type: Field::Select.with_options(
      collection: ModelAssignment::SCOPES,
      searchable: false
    ),
    # scope_id holds the Page/Account id; leave blank for the System scope.
    scope_id: Field::Number,
    function: Field::Select.with_options(
      collection: ModelAssignment::FUNCTIONS,
      searchable: false
    ),
    ai_model: Field::BelongsTo,
    # Administrate resolves the AiModel class/dashboard from the association's
    # declared class_name (belongs_to :fallback_ai_model, class_name: "AiModel").
    fallback_ai_model: Field::BelongsTo,
    options: Field::Text,
    created_at: Field::DateTime,
    updated_at: Field::DateTime
  }.freeze

  # COLLECTION_ATTRIBUTES
  # an array of attributes that will be displayed on the model's index page.
  #
  # By default, it's limited to four items to reduce clutter on index pages.
  # Feel free to add, remove, or rearrange items.
  COLLECTION_ATTRIBUTES = %i[
    scope_type
    scope_id
    function
    ai_model
  ].freeze

  # SHOW_PAGE_ATTRIBUTES
  # an array of attributes that will be displayed on the model's show page.
  SHOW_PAGE_ATTRIBUTES = %i[
    id
    scope_type
    scope_id
    function
    ai_model
    fallback_ai_model
    options
    created_at
    updated_at
  ].freeze

  # FORM_ATTRIBUTES
  # an array of attributes that will be displayed
  # on the model's form (`new` and `edit`) pages.
  FORM_ATTRIBUTES = %i[
    scope_type
    scope_id
    function
    ai_model
    fallback_ai_model
    options
  ].freeze

  # COLLECTION_FILTERS
  # a hash that defines filters that can be used while searching via the search
  # field of the dashboard.
  COLLECTION_FILTERS = {}.freeze

  # Overwrite this method to customize how model assignments are displayed
  # across all pages of the admin dashboard.
  def display_resource(model_assignment)
    scope = model_assignment.scope_type
    scope += " ##{model_assignment.scope_id}" if model_assignment.scope_id.present?
    "#{scope} / #{model_assignment.function}"
  end
end
