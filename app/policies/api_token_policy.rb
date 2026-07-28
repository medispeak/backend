# API keys belong to the user who minted them and carry that user's account
# scope, so only the owner (or an admin) may read or revoke one.
class ApiTokenPolicy < ApplicationPolicy
  def index?
    user.present?
  end

  def show?
    owner_or_admin?
  end

  def new?
    user.present?
  end

  def create?
    new?
  end

  def destroy?
    owner_or_admin?
  end

  private

  def owner_or_admin?
    return false if user.blank?
    return true if user.admin?

    record.user_id == user.id
  end

  class Scope < Scope
    def resolve
      return scope.none if user.blank?
      return scope.all if user.admin?

      scope.where(user_id: user.id)
    end
  end
end
