class TemplatePolicy < ApplicationPolicy
  def index?
    true
  end

  def show?
    true
  end

  def find_by_domain?
    true
  end

  def new?
    user.present?
  end

  def create?
    new?
  end

  def edit?
    update?
  end

  def update?
    return false unless user.present?

    user.admin? || owns?
  end

  def destroy?
    update?
  end

  # An admin may act on any template; a regular user only on their own account's.
  # Legacy templates with no owner (account_id NULL) are admin-only-editable.
  class Scope < Scope
    def resolve
      return scope.all if user&.admin?

      scope.where(account_id: user&.account_id)
    end
  end

  private

  def owns?
    user.present? && record.account_id.present? && record.account_id == user.account_id
  end
end
