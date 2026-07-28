# The Overview is the first screen after sign-in. It answers two questions —
# what happened recently, and is the account healthy — using only figures the
# models actually record.
#
# Every query is scoped to the signed-in user's OWN account rather than its
# subtree, so these numbers agree with what Consultations and Usage show for
# the same person.
class DashboardController < ApplicationController
  RECENT_SESSION_LIMIT = 8

  def show
    # A user normally always has an account (User#ensure_account on create), but
    # Account has_many :users, dependent: :nullify — deleting an account leaves
    # its users behind with account_id nil. Those users can still sign in, and
    # AccountsController#require_account redirects them HERE, so this page has to
    # survive the state rather than raise (`authorize nil` => NotDefinedError).
    return render_without_account if current_account.blank?

    # Otherwise the page authorizes the real record it is about instead of
    # skipping the check.
    authorize current_account, :show?

    month = Time.current.all_month

    @recent_sessions = account_sessions.includes(:scribe_outputs)
                                       .order(created_at: :desc)
                                       .limit(RECENT_SESSION_LIMIT)
                                       .to_a

    @sessions_this_month = account_sessions.where(created_at: month).count
    @transcription_minutes = account_usage.where(created_at: month).sum(:audio_seconds).to_f / 60
    @spend_this_month = account_usage.finalized.where(created_at: month).sum(:cost)

    # Credit is optional: an account with no AccountCredit row is not
    # "unlimited", it simply is not on credit, so the card is omitted entirely
    # rather than shown with a made-up number.
    @account_credit = current_account.account_credit

    @api_tokens_count = current_account.api_tokens.count
    # A limit-8 list that comes back empty means the account has no sessions at
    # all, so the onboarding decision costs no extra query.
    @onboarding = @recent_sessions.empty? && @api_tokens_count.zero?
  end

  private

  # There is no record to authorize and nothing to report on, so the page says
  # exactly that instead of rendering four zeroes and an onboarding checklist
  # the user cannot act on.
  def render_without_account
    skip_authorization
    render :no_account
  end

  # policy_scope hands an admin every account's sessions, so the account filter
  # stays on top of it: the Overview is always about one account.
  def account_sessions
    policy_scope(ScribeSession).where(account_id: current_account.id)
  end

  def account_usage
    current_account.usage_events
  end
end
