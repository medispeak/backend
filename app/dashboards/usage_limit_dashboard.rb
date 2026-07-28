require "administrate/base_dashboard"

class UsageLimitDashboard < Administrate::BaseDashboard
  # A usage cap attached to one tenancy-tree node. scope "subtree" caps the
  # node's whole subtree in aggregate; "per_user" caps each individual user
  # under the node. Enforced at commit time by Metering::LimitGuard.
  ATTRIBUTE_TYPES = {
    id: Field::Number,
    account: Field::BelongsTo,
    scope: Field::Select.with_options(collection: UsageLimit::SCOPES, searchable: false),
    metric: Field::Select.with_options(collection: UsageLimit::METRICS, searchable: false),
    period: Field::Select.with_options(collection: UsageLimit::PERIODS, searchable: false),
    limit_value: Field::String,
    created_at: Field::DateTime,
    updated_at: Field::DateTime
  }.freeze

  COLLECTION_ATTRIBUTES = %i[
    account
    scope
    metric
    period
    limit_value
  ].freeze

  SHOW_PAGE_ATTRIBUTES = %i[
    id
    account
    scope
    metric
    period
    limit_value
    created_at
    updated_at
  ].freeze

  FORM_ATTRIBUTES = %i[
    account
    scope
    metric
    period
    limit_value
  ].freeze

  COLLECTION_FILTERS = {}.freeze

  def display_resource(usage_limit)
    "#{usage_limit.scope}/#{usage_limit.metric}/#{usage_limit.period} @ #{usage_limit.account&.name}"
  end
end
