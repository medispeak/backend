module Api
  module V2
    # Account usage summary aggregated from finalized usage events.
    #
    # Backward-compatible params (all optional; the bare GET /usage response is
    # unchanged):
    #   from / to           ISO8601 time window (defaults: all time)
    #   scope=subtree       aggregate the account's whole tenancy subtree
    #                       (default: this account only)
    #   user_id=N           filter to one user; 404 unless that user's account
    #                       is inside the caller's subtree (no cross-tenant
    #                       probing)
    #   group_by=user|account|model   adds by_user / by_account arrays shaped
    #                       like the existing by_model (model grouping is
    #                       always included, as before)
    class UsageController < BaseController
      # Account-wide usage summary: a scoped session token must not reach it.
      before_action :require_account_token!

      # GET /api/v2/usage
      def show
        events = UsageEvent.where(status: "finalized", account_id: scoped_account_ids)

        if params[:user_id].present?
          user = User.find_by(id: params[:user_id], account_id: scoped_account_ids)
          unless user
            render_error(code: "user_not_found", message: "User not found", status: :not_found)
            return
          end
          events = events.where(user_id: user.id)
        end

        events = events.where(created_at: time_window) if time_window

        payload = {
          total_cost: events.sum(:cost).to_f,
          total_tokens: events.sum(:total_tokens),
          total_audio_seconds: events.sum(:audio_seconds).to_f,
          by_model: grouped(events, :model)
        }
        payload[:by_user] = grouped(events, :user_id) if group_by == "user"
        payload[:by_account] = grouped(events, :account_id) if group_by == "account"

        render json: payload, status: :ok
      end

      private

      def scoped_account_ids
        @scoped_account_ids ||=
          params[:scope] == "subtree" ? current_account.subtree_ids : [ current_account.id ]
      end

      def group_by
        params[:group_by].presence
      end

      # nil (no filter) unless at least one bound parses; a malformed bound is
      # ignored rather than 500ing.
      def time_window
        return @time_window if defined?(@time_window)

        from = parse_time(params[:from])
        to = parse_time(params[:to])
        @time_window = (from || to) ? ((from || Time.at(0))..(to || Time.current)) : nil
      end

      def parse_time(value)
        value.present? ? Time.zone.parse(value.to_s) : nil
      rescue ArgumentError
        nil
      end

      def grouped(events, key)
        events.group(key).pluck(
          key,
          Arel.sql("SUM(cost)"),
          Arel.sql("SUM(total_tokens)"),
          Arel.sql("SUM(audio_seconds)")
        ).map do |group_value, cost, tokens, audio_seconds|
          {
            (key == :model ? :model : key) => group_value,
            cost: cost.to_f,
            total_tokens: tokens.to_i,
            audio_seconds: audio_seconds.to_f
          }
        end
      end
    end
  end
end
