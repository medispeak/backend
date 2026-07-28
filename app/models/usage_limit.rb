# A usage cap attached to one tenancy-tree node (Metering::LimitGuard enforces
# every limit on the leaf-to-root chain at admission time).
#
#   scope  "subtree":  the aggregate usage of this node's whole subtree must
#                      stay under limit_value per period.
#          "per_user": EACH individual user's usage (anywhere under this node)
#                      must stay under limit_value per period.
#   metric "tokens" (total_tokens) | "cost" (priced cost, account currency).
#   period calendar "daily" | "monthly" windows in the app time zone.
class UsageLimit < ApplicationRecord
  SCOPES = %w[subtree per_user].freeze
  METRICS = %w[tokens cost].freeze
  PERIODS = %w[daily monthly].freeze

  belongs_to :account

  validates :scope, presence: true, inclusion: { in: SCOPES }
  validates :metric, presence: true, inclusion: { in: METRICS }
  validates :period, presence: true, inclusion: { in: PERIODS }
  validates :limit_value, presence: true, numericality: { greater_than: 0 }
  validates :scope, uniqueness: { scope: %i[account_id metric period] }
end
