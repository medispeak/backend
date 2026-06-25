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
    user.present?
  end

  def update?
    edit?
  end

  def destroy?
    user.present?
  end

  class Scope < Scope
    def resolve
      Template.all
    end
  end
end
