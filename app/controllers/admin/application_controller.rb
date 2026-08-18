# All Administrate controllers inherit from this
# `Administrate::ApplicationController`, making it the ideal place to put
# authentication logic or other before_actions.
#
# If you want to add pagination or other controller-level concerns,
# you're free to overwrite the RESTful controller actions.
module Admin
  class ApplicationController < Administrate::ApplicationController
    # Repeated from ::ApplicationController on purpose: Administrate's base
    # class descends from ActionController::Base, so this namespace inherits
    # none of the app's overrides. Without it, current_user here would stay the
    # real admin and /admin would remain open during an impersonation — the one
    # failure that would look like it worked.
    impersonates :user

    before_action :authenticate_admin

    # authenticate_user! is Warden's and still sees the real admin (pretender
    # never touches the session), so the admin stays logged in; it is admin?
    # going false on the impersonated current_user that closes this namespace.
    def authenticate_admin
      authenticate_user!
      redirect_to root_path, alert: "Not authorized." unless current_user.admin?
    end

    # Override this value to specify the number of elements to display at a time
    # on index pages. Defaults to 20.
    # def records_per_page
    #   params[:per_page] || 20
    # end
  end
end
