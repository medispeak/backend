# Ending an impersonation. Deliberately NOT under /admin: admin? is false for
# the duration, so that namespace is closed to the very person who needs to get
# out of it. This is the one door that has to stay on the outside.
class ImpersonationsController < ApplicationController
  # DELETE is a write, and the read-only guard blocks writes while
  # impersonating — which would make the exit unreachable.
  skip_before_action :enforce_read_only_while_impersonating

  # There is no record to authorize here: the action's whole effect is on the
  # requester's own session, and the guard below is the authorization.
  skip_after_action :verify_authorized

  def destroy
    return redirect_to root_path unless impersonating?

    was = current_user
    stop_impersonating_user
    # Back to where the admin started, rather than to a generic admin root.
    redirect_to admin_user_path(was), notice: "Stopped viewing as #{was.email}."
  end
end
