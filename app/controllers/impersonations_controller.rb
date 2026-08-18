# Outside /admin by necessity: admin? is false while impersonating, so that
# namespace is closed to the person who needs the exit.
class ImpersonationsController < ApplicationController
  # The exit is itself a write, and acts only on the requester's own session.
  skip_before_action :enforce_read_only_while_impersonating
  skip_after_action :verify_authorized

  def destroy
    return redirect_to root_path unless impersonating?

    was = current_user
    stop_impersonating_user
    redirect_to admin_user_path(was), notice: "Stopped viewing as #{was.email}."
  end
end
