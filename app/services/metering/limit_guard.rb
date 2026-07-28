module Metering
  # Pure-read admission gate for UsageLimit caps — deliberately NOT a second
  # ledger. Limits are windowed SUMs over the immutable usage_events table
  # (calendar day/month in the app time zone); AccountCredit/CreditTransaction
  # remain the money system (QuotaGuard).
  #
  # Every limit attached to any node on the account's leaf-to-root chain must
  # pass. "subtree" limits aggregate the limit node's whole subtree; "per_user"
  # limits cap the acting user's own usage (summed globally by user_id, so a
  # user moving between facilities mid-window cannot reset a cap).
  #
  # Concurrency: lock-free soft caps. Two racing commits can both pass and
  # overshoot by ~one session — the same postpaid tolerance QuotaGuard.hold!
  # already accepts. Pending events count toward the window (only failed events
  # are excluded), which narrows that overshoot. Accounts on a chain with no
  # UsageLimit rows are unlimited (one indexed query, no sums).
  class LimitGuard
    Result = Struct.new(:ok, :violation, keyword_init: true) do
      def ok?
        !!ok
      end
    end

    # violation payload: the failing limit plus the measured window usage.
    Violation = Struct.new(:limit, :used, keyword_init: true)

    class << self
      # account: the session's account (leaf node). user: the acting user (nil
      # skips per_user limits — subtree limits still guard unattributed
      # traffic). estimated_cost: a conservative pre-flight estimate added to
      # cost-metric sums so a commit that would cross a budget is blocked
      # before it runs.
      def check(account:, user: nil, estimated_cost: 0)
        limits = UsageLimit.where(account_id: account.self_and_ancestors.map(&:id))
        return Result.new(ok: true) if limits.empty?

        limits.each do |limit|
          next if limit.scope == "per_user" && user.nil?

          used = window_usage(limit, account, user)
          projected = used + (limit.metric == "cost" ? estimated_cost.to_d : 0)

          # Block at the cap: token caps carry no pre-flight estimate, so >=
          # stops the next request once the cap is reached; cost projections
          # use the same comparison for consistency (the estimate is
          # deliberately conservative).
          if projected >= limit.limit_value
            return Result.new(ok: false, violation: Violation.new(limit: limit, used: used))
          end
        end

        Result.new(ok: true)
      end

      private

      def window_usage(limit, account, user)
        events = UsageEvent.where(created_at: window_for(limit.period))
                           .where.not(status: "failed")
        events =
          case limit.scope
          when "subtree" then events.where(account_id: limit.account.subtree_ids)
          when "per_user" then events.where(user_id: user.id)
          end

        column = limit.metric == "tokens" ? :total_tokens : :cost
        events.sum(column).to_d
      end

      def window_for(period)
        now = Time.zone.now
        period == "daily" ? now.all_day : now.all_month
      end
    end
  end
end
