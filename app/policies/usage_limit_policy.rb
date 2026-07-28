# Usage limits hang off an account node; managing them is an account-owner
# (or admin) action, delegated to AccountPolicy so the rule lives in one place.
class UsageLimitPolicy < ApplicationPolicy
  def create?
    AccountPolicy.new(user, record.account).manage_limits?
  end

  def destroy?
    create?
  end

  class Scope < Scope
    def resolve
      return scope.none if user.blank?
      return scope.all if user.admin?

      scope.where(account_id: user.account_id)
    end
  end
end
