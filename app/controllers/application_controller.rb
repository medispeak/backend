class ApplicationController < ActionController::Base
  include Pundit::Authorization
  include Pagy::Backend
  include Sortable

  # Only allow modern browsers supporting webp images, web push, badges, import
  # maps, CSS nesting, and CSS :has.
  allow_browser versions: :modern

  # The UI is private by default: every controller requires a signed-in user
  # and an explicit authorization call. A surface that should be public opts
  # out deliberately rather than by omission.
  #
  # Devise's own controllers inherit from this class (config.parent_controller
  # defaults to ApplicationController), so they are exempt: requiring a login to
  # reach the login page is a redirect loop, and Devise has no Pundit policies.
  # The action is matched at runtime rather than through the callbacks' :only /
  # :except options, because Rails raises AbstractController::ActionNotFound
  # when those name an action a subclass does not define — and singular-resource
  # controllers (usage, account) legitimately have no :index.
  before_action :authenticate_user!, unless: :devise_controller?
  after_action :verify_authorized, unless: -> { devise_controller? || action_name == "index" }
  after_action :verify_policy_scoped, if: -> { !devise_controller? && action_name == "index" }

  rescue_from Pundit::NotAuthorizedError, with: :user_not_authorized

  def pundit_user
    current_user
  end

  private

  # Pundit denials are a redirect, not a 500. Three controllers previously
  # declared `rescue_from ..., with: :user_not_authorized` without defining the
  # method, so every denial raised NoMethodError.
  def user_not_authorized
    respond_to do |format|
      format.html do
        redirect_back fallback_location: root_path,
                      alert: "You are not authorized to do that."
      end
      format.json { render json: { error: "not_authorized" }, status: :forbidden }
    end
  end

  # The account whose data the current user sees. Every tenant-scoped query
  # hangs off this rather than off current_user directly.
  def current_account
    current_user&.account
  end
  helper_method :current_account
end
