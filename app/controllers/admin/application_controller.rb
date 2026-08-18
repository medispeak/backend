# All Administrate controllers inherit from this
# `Administrate::ApplicationController`, making it the ideal place to put
# authentication logic or other before_actions.
#
# If you want to add pagination or other controller-level concerns,
# you're free to overwrite the RESTful controller actions.
module Admin
  class ApplicationController < Administrate::ApplicationController
    # Required here too: this namespace inherits nothing from
    # ::ApplicationController, so without it /admin stays open mid-impersonation.
    impersonates :user

    before_action :authenticate_admin

    # Warden still sees the real admin; it is admin? going false on the
    # impersonated current_user that closes this namespace.
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
