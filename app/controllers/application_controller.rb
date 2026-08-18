class ApplicationController < ActionController::Base
  include Pundit::Authorization
  include Pagy::Backend
  include Sortable

  # Only allow modern browsers supporting webp images, web push, badges, import
  # maps, CSS nesting, and CSS :has.
  allow_browser versions: :modern

  # Admin "view as user". current_user becomes the impersonated user, so every
  # tenant-scoped surface follows without changes: current_account and
  # pundit_user below already hang off it, and User#admin? goes false, which is
  # what closes /admin for the duration.
  #
  # This is declared again in Admin::ApplicationController — Administrate's base
  # class descends from ActionController::Base, NOT from this class, so it does
  # not inherit the override. Without both, /admin would keep seeing the real
  # admin and stay open mid-impersonation.
  impersonates :user

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
  before_action :enforce_read_only_while_impersonating
  after_action :verify_authorized, unless: -> { devise_controller? || action_name == "index" }
  after_action :verify_policy_scoped, if: -> { !devise_controller? && action_name == "index" }

  rescue_from Pundit::NotAuthorizedError, with: :user_not_authorized

  def pundit_user
    current_user
  end

  # Compared against true_user rather than reading pretender's session key, so
  # this keeps working if the gem renames it.
  def impersonating?
    current_user.present? && current_user != true_user
  end
  helper_method :impersonating?

  private

  # Impersonation is a viewing tool: the admin sees the tenant's data but never
  # acts as them. A blanket verb check is the whole enforcement — policies stay
  # untouched, so there is no per-policy rule to remember on the next feature.
  # Anything that legitimately writes while impersonating (only the exit route
  # today) skips this callback explicitly.
  def enforce_read_only_while_impersonating
    return unless impersonating?
    return if request.get? || request.head?

    redirect_back fallback_location: root_path,
                  alert: "You are viewing as #{current_user.email} — this is read-only."
  end

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
