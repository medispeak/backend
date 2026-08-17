module Admin
  class UsersController < Admin::ApplicationController
    # Start viewing the app as this user. The redirect leaves /admin because
    # this request is the last one that still has admin powers — from the next
    # one on, current_user is the target and authenticate_admin turns us away.
    def impersonate
      target = User.find(params[:id])

      # Privileges follow the impersonated identity, so impersonating another
      # admin would hand straight back the powers this feature exists to drop —
      # and with them the ability to write, defeating the read-only guard.
      if target.admin?
        return redirect_to admin_user_path(target),
                           alert: "Cannot view as another admin."
      end

      impersonate_user(target)
      redirect_to root_path, notice: "Now viewing as #{target.email}."
    end

    # Overwrite any of the RESTful controller actions to implement custom behavior
    # For example, you may want to send an email after a foo is updated.
    #
    # def update
    #   super
    #   send_foo_updated_email(requested_resource)
    # end

    # Override this method to specify custom lookup behavior.
    # This will be used to set the resource for the `show`, `edit`, and `update`
    # actions.
    #
    # def find_resource(param)
    #   Foo.find_by!(slug: param)
    # end

    # The result of this lookup will be available as `requested_resource`

    # Override this if you have certain roles that require a subset
    # this will be used to set the records shown on the `index` action.
    #
    # def scoped_resource
    #   if current_user.super_admin?
    #     resource_class
    #   else
    #     resource_class.with_less_stuff
    #   end
    # end

    # Override `resource_params` if you want to transform the submitted
    # data before it's persisted. For example, the following would turn all
    # empty values into nil values. It uses other APIs such as `resource_class`
    # and `dashboard`:
    #
    # def resource_params
    #   params.require(resource_class.model_name.param_key).
    #     permit(dashboard.permitted_attributes(action_name)).
    #     transform_values { |value| value == "" ? nil : value }
    # end

    # See https://administrate-demo.herokuapp.com/customizing_controller_actions
    # for more information
  end
end
