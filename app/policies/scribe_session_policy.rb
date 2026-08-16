# Consultations are account data. A user sees their own account's sessions;
# an admin sees everything. Sessions are produced by the API and by the
# template playground, and are never edited through the UI — so beyond
# create?, this stays read-only.
class ScribeSessionPolicy < ApplicationPolicy
  def index?
    user.present?
  end

  # The playground is the one UI surface that starts a session. It needs an
  # account to bill and scope against, which rules out an admin with no account
  # of their own — unlike show?, admin is not a bypass here.
  def create?
    user.present? && user.account_id.present?
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
