module Api
  module V2
    # Discovery endpoint: supported languages, available templates, and the
    # account's effective limits.
    class ConfigController < BaseController
      # GET /api/v2/config
      def show
        render json: {
          languages: %w[en hi ta auto],
          templates: Template.where(archived: false).map { |t| { id: t.id, name: t.name } },
          limits: { rpm: current_account.settings["rpm"] || 120 }
        }, status: :ok
      end
    end
  end
end
