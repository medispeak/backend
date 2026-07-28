# Templates are tenant data: only the owning account (or an admin) may read or
# write them. Legacy templates with a NULL account_id are admin-only. Reads used
# to be unconditionally public — index?/show? returned true — which exposed every
# account's form schemas and prompts to anonymous visitors.
class TemplatePolicy < ApplicationPolicy
  def index?
    user.present?
  end

  def show?
    owned_or_admin?
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
    owned_or_admin?
  end

  def destroy?
    update?
  end

  class Scope < Scope
    def resolve
      return scope.none if user.blank?
      return scope.all if user.admin?

      scope.where(account_id: user.account_id)
    end
  end

  private

  def owned_or_admin?
    return false if user.blank?
    return true if user.admin?

    record.account_id.present? && record.account_id == user.account_id
  end
end
