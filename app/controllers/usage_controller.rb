# Spend and volume reporting for the signed-in user's account.
#
# Every figure here is a SQL aggregate. An account can accumulate tens of
# thousands of usage events, so nothing on this page loads a collection of them
# into Ruby — the only Ruby-side loops run over already-grouped rows (at most
# one per capability, model, user or limit).
#
# Two windows live on this page, and they are deliberately different:
#
#   * the report — stat cards and the three breakdowns — covers the period the
#     user picked and counts only FINALIZED events, i.e. settled charges;
#   * the limits card ignores that period entirely and mirrors
#     Metering::LimitGuard: each cap's own calendar window, and every event
#     except failed ones (pending usage counts against a cap). Anything else
#     would let someone watch a bar sit at 60% and still be refused.
#
# Like the Overview, the report is scoped to the account itself rather than its
# subtree, so the numbers agree with what Consultations shows the same person.
class UsageController < ApplicationController
  # A user is normally given an account on create (User#ensure_account), but
  # `Account has_many :users, dependent: :nullify` means deleting an account
  # leaves its users unlinked. Bail before authorization — as AccountsController
  # does — so the halted chain skips verify_authorized instead of handing Pundit
  # a nil record (which raises NotDefinedError, a 500, not a denial).
  before_action :require_account

  PERIODS = %w[month week all].freeze

  # Pipeline order, so the capability table lists transcription before
  # structuring whether or not a given period happens to contain both.
  FUNCTION_ORDER = UsageEvent.functions.keys.freeze

  def show
    authorize current_account, :show?

    @period = PERIODS.include?(params[:period]) ? params[:period] : "month"
    @range = report_range

    events = report_events
    load_totals(events)
    @session_count = session_count
    @by_function = by_function(events)
    @by_model = by_model(events)

    # A per-user split is noise on a single-clinician account, so it is not
    # even queried unless there is more than one user to split.
    @user_count = current_account.users.count
    @by_user = @user_count > 1 ? by_user(events) : []

    @limits = limits_with_usage
  end

  private

  def require_account
    return if current_account.present?

    redirect_to root_path, alert: "Your login is not linked to an account yet."
  end

  # Calendar windows in the app time zone — the same shape UsageLimit periods
  # use, so "this month" means one thing on the whole page. "all" is no filter.
  def report_range
    case @period
    when "week" then Time.current.all_week
    when "all" then nil
    else Time.current.all_month
    end
  end

  # Settled charges only: a pending event has no final cost yet and a failed
  # one is never billed.
  def report_events
    scope = UsageEvent.where(account_id: current_account.id, status: "finalized")
    @range ? scope.where(created_at: @range) : scope
  end

  # One pass over the window for all five sums; COALESCE keeps an empty account
  # at 0 rather than nil.
  def load_totals(events)
    cost, tokens, audio_seconds, pages, count = events.pick(
      Arel.sql("COALESCE(SUM(cost), 0)"),
      Arel.sql("COALESCE(SUM(total_tokens), 0)"),
      Arel.sql("COALESCE(SUM(audio_seconds), 0)"),
      Arel.sql("COALESCE(SUM(pages), 0)"),
      Arel.sql("COUNT(*)")
    )

    @total_cost = cost
    @total_tokens = tokens
    @transcription_minutes = audio_seconds.to_f / 60
    @document_pages = pages
    @event_count = count
  end

  # Consultations are counted from the sessions themselves, not from usage
  # events: a session that failed before anything was metered still happened.
  def session_count
    scope = ScribeSession.where(account_id: current_account.id)
    scope = scope.where(created_at: @range) if @range
    scope.count
  end

  def by_function(events)
    rows = events.group(:function).pluck(
      :function,
      Arel.sql("COUNT(*)"),
      Arel.sql("COALESCE(SUM(total_tokens), 0)"),
      Arel.sql("COALESCE(SUM(cost), 0)")
    )

    rows.map { |function, count, tokens, cost|
      { function: function, count: count, tokens: tokens, cost: cost }
    }.sort_by { |row| FUNCTION_ORDER.index(row[:function]) || FUNCTION_ORDER.size }
  end

  # Sorted by spend: the question this table answers is "what is costing me
  # money", so the answer is the first row.
  def by_model(events)
    events.group(:model, :provider)
          .order(Arel.sql("COALESCE(SUM(cost), 0) DESC"))
          .pluck(
            :model,
            :provider,
            Arel.sql("COUNT(*)"),
            Arel.sql("COALESCE(SUM(total_tokens), 0)"),
            Arel.sql("COALESCE(SUM(cost), 0)")
          )
          .map do |model, provider, count, tokens, cost|
            { model: model, provider: provider, count: count, tokens: tokens, cost: cost }
          end
  end

  # The grouped rows carry user ids; the emails come back in a single extra
  # query keyed by id, never one lookup per row. Events posted with an account
  # token carry no user at all, so email may be nil.
  def by_user(events)
    rows = events.group(:user_id)
                 .order(Arel.sql("COALESCE(SUM(cost), 0) DESC"))
                 .pluck(
                   :user_id,
                   Arel.sql("COUNT(*)"),
                   Arel.sql("COALESCE(SUM(total_tokens), 0)"),
                   Arel.sql("COALESCE(SUM(cost), 0)")
                 )

    emails = User.where(id: rows.map(&:first).compact).pluck(:id, :email).to_h

    rows.map do |user_id, count, tokens, cost|
      { email: emails[user_id], count: count, tokens: tokens, cost: cost }
    end
  end

  # Every cap on the leaf-to-root chain applies, exactly as LimitGuard resolves
  # them at admission time.
  def limits_with_usage
    limits = UsageLimit.where(account_id: current_account.self_and_ancestors.map(&:id))
                       .includes(:account)
                       .order(:period, :metric, :scope)

    subtrees = {}

    limits.map do |limit|
      account_ids = (subtrees[limit.account_id] ||= limit.account.subtree_ids)
      used = window_usage(limit, account_ids)
      cap = limit.limit_value.to_d

      {
        limit: limit,
        used: used,
        # The guard blocks AT the cap (projected >= limit_value), so a full bar
        # means the next request is already being refused.
        blocked: used >= cap,
        percent: cap.positive? ? [ (used / cap * 100).to_f, 100.0 ].min.round : 0
      }
    end
  end

  # Mirrors Metering::LimitGuard#window_usage: same calendar window, the same
  # "everything except failed" filter, the same subtree / per_user split. Read
  # app/services/metering/limit_guard.rb before changing this.
  def window_usage(limit, account_ids)
    events = UsageEvent.where(created_at: limit_window(limit.period))
                       .where.not(status: "failed")
    events =
      case limit.scope
      when "subtree" then events.where(account_id: account_ids)
      # A per_user cap constrains the ACTING user, summed globally by user_id.
      # On this page the acting user is the person reading it, so the bar shows
      # their own standing against the cap.
      when "per_user" then events.where(user_id: current_user.id)
      end

    events.sum(limit.metric == "tokens" ? :total_tokens : :cost).to_d
  end

  def limit_window(period)
    now = Time.zone.now
    period == "daily" ? now.all_day : now.all_month
  end
end
