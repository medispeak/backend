require "administrate/base_dashboard"

class FormFieldDashboard < Administrate::BaseDashboard
  # ATTRIBUTE_TYPES
  # a hash that describes the type of each of the model's fields.
  #
  # Each different type represents an Administrate::Field object,
  # which determines how the attribute is displayed
  # on pages throughout the dashboard.
  ATTRIBUTE_TYPES = {
    id: Field::Number,
    description: Field::String,
    friendly_name: Field::String,
    field_type: Field::Select.with_options(
      collection: FormField.field_types.keys.map { |t| [ t.humanize, t ] }
    ),
    # jsonb object edited as JSON text; the model (JsonObjectColumns) parses it.
    metadata: Field::JsonObject.with_options(searchable: false, hint: "JSON object, e.g. {}"),
    minimum: Field::String,
    maximum: Field::String,
    enum_options: Field::StringArray.with_options(
      hint: "Enter options for single/multi select fields, one per line"
    ),
    page: Field::BelongsTo,
    title: Field::String,
    created_at: Field::DateTime,
    updated_at: Field::DateTime
  }.freeze

  # COLLECTION_ATTRIBUTES
  # an array of attributes that will be displayed on the model's index page.
  #
  # By default, it's limited to four items to reduce clutter on index pages.
  # Feel free to add, remove, or rearrange items.
  COLLECTION_ATTRIBUTES = %i[
    id
    title
    friendly_name
    field_type
    description
    page
  ].freeze

  # SHOW_PAGE_ATTRIBUTES
  # an array of attributes that will be displayed on the model's show page.
  SHOW_PAGE_ATTRIBUTES = %i[
    id
    title
    friendly_name
    field_type
    description
    page
    metadata
    minimum
    maximum
    enum_options
    created_at
    updated_at
  ].freeze

  # FORM_ATTRIBUTES
  # an array of attributes that will be displayed
  # on the model's form (`new` and `edit`) pages.
  FORM_ATTRIBUTES = %i[
    page
    friendly_name
    title
    description
    metadata
    field_type
    minimum
    maximum
    enum_options
  ].freeze

  # COLLECTION_FILTERS
  # a hash that defines filters that can be used while searching via the search
  # field of the dashboard.
  #
  # For example to add an option to search for open resources by typing "open:"
  # in the search field:
  #
  #   COLLECTION_FILTERS = {
  #     open: ->(resources) { resources.where(open: true) }
  #   }.freeze
  COLLECTION_FILTERS = {}.freeze

  # Overwrite this method to customize how form fields are displayed
  # across all pages of the admin dashboard.
  #
  def display_resource(form_field)
    "FormField ##{form_field.id}"
  end
end
