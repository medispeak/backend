# A user may view and edit their own account. Account settings are operational
# (name, webhook callback default), not billing — credits and limits are
# adjusted by an admin.
class AccountPolicy < ApplicationPolicy
  def show?
    own_account? || user&.admin?
  end

  def edit?
    update?
  end

  def update?
    own_account? || user&.admin?
  end

  # Spending caps constrain the account's own users, so an account owner may
  # set them; only an admin can raise a cap on an ancestor node.
  def manage_limits?
    own_account? || user&.admin?
  end

  private

  def own_account?
    user.present? && record.present? && record.id == user.account_id
  end

  class Scope < Scope
    def resolve
      return scope.none if user.blank?
      return scope.all if user.admin?

      scope.where(id: user.account_id)
    end
  end
end
