require "administrate/base_dashboard"

class AccountDashboard < Administrate::BaseDashboard
  # ATTRIBUTE_TYPES
  # a hash that describes the type of each of the model's fields.
  #
  # Each different type represents an Administrate::Field object,
  # which determines how the attribute is displayed
  # on pages throughout the dashboard.
  # account_credit / api_tokens are shown as scalar summaries (credit_balance,
  # api_tokens_count) rather than association links, because those models have
  # no Administrate dashboards (linking to them would raise).
  ATTRIBUTE_TYPES = {
    id: Field::Number,
    name: Field::String,
    status: Field::String,
    # jsonb object edited as JSON text; the model (JsonObjectColumns) parses it.
    settings: Field::JsonObject.with_options(
      hint: 'JSON object of account settings, e.g. {"rpm": 300}'
    ),
    parent: Field::BelongsTo.with_options(class_name: "Account"),
    children: Field::HasMany.with_options(class_name: "Account"),
    usage_limits: Field::HasMany,
    credit_balance: Field::String,
    api_tokens_count: Field::Number,
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
    name
    parent
    status
    credit_balance
  ].freeze

  # SHOW_PAGE_ATTRIBUTES
  # an array of attributes that will be displayed on the model's show page.
  SHOW_PAGE_ATTRIBUTES = %i[
    id
    name
    status
    settings
    parent
    children
    usage_limits
    credit_balance
    api_tokens_count
    created_at
    updated_at
  ].freeze

  # FORM_ATTRIBUTES
  # an array of attributes that will be displayed
  # on the model's form (`new` and `edit`) pages.
  FORM_ATTRIBUTES = %i[
    name
    status
    settings
    parent
  ].freeze

  # COLLECTION_FILTERS
  # a hash that defines filters that can be used while searching via the search
  # field of the dashboard.
  COLLECTION_FILTERS = {}.freeze

  # Overwrite this method to customize how accounts are displayed
  # across all pages of the admin dashboard.
  def display_resource(account)
    account.name
  end
end
