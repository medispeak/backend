# Consultations are account data. A user sees their own account's sessions;
# an admin sees everything. Sessions are produced by the API, never edited
# through the UI, so this is read-only.
class ScribeSessionPolicy < ApplicationPolicy
  def index?
    user.present?
  end

  def show?
    return false if user.blank?
    return true if user.admin?

    record.account_id == user.account_id
  end

  class Scope < Scope
    def resolve
      return scope.none if user.blank?
      return scope.all if user.admin?

      scope.where(account_id: user.account_id)
    end
  end
end
