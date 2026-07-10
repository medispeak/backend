module Api
  module V2
    # Account usage summary aggregated from finalized usage events.
    class UsageController < BaseController
      # Account-wide usage summary: a scoped session token must not reach it.
      before_action :require_account_token!

      # GET /api/v2/usage
      def show
        events = current_account.usage_events.where(status: "finalized")

        render json: {
          total_cost: events.sum(:cost).to_f,
          total_tokens: events.sum(:total_tokens),
          total_audio_seconds: events.sum(:audio_seconds).to_f,
          by_model: by_model(events)
        }, status: :ok
      end

      private

      def by_model(events)
        events.group(:model).pluck(
          :model,
          Arel.sql("SUM(cost)"),
          Arel.sql("SUM(total_tokens)"),
          Arel.sql("SUM(audio_seconds)")
        ).map do |model, cost, tokens, audio_seconds|
          {
            model: model,
            cost: cost.to_f,
            total_tokens: tokens.to_i,
            audio_seconds: audio_seconds.to_f
          }
        end
      end
    end
  end
end
