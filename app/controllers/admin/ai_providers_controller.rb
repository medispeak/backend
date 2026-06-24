module Admin
  class AiProvidersController < Admin::ApplicationController
    # SECURITY: api_key is encrypted at rest. On edit, a blank submission means
    # "leave unchanged" rather than wiping the stored secret to an empty string.
    def resource_params
      permitted = params.require(resource_class.model_name.param_key)
                        .permit(dashboard.permitted_attributes(action_name))

      if action_name == "update" && permitted[:api_key].blank?
        permitted = permitted.except(:api_key)
      end

      permitted
    end
  end
end
