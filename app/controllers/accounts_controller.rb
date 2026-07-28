# The account settings surface: who you are in the tenancy tree, who is on the
# team, what you may spend. There is exactly one account per signed-in user, so
# this is a singular resource — the record is always `current_account` and is
# never looked up from params (a params id here would be a tenancy hole).
class AccountsController < ApplicationController
  before_action :require_account
  before_action :set_account

  # "subtree" / "per_user" are the storage words; these are the words a customer
  # reads. Used by both the caps table and the add-cap form.
  SCOPE_LABELS = {
    "subtree" => "Whole account",
    "per_user" => "Each user"
  }.freeze

  helper_method :usage_limit_scope_label

  # GET /account
  def show
    authorize @account, :show?

    @credit = @account.account_credit
    @lineage = @account.self_and_ancestors.reverse   # root -> ... -> this account
    @children = @account.children.order(:name)
    @members = @account.users.order(:created_at)

    @usage_limits = @account.usage_limits.order(:metric, :period, :scope)
    @inherited_limits = inherited_limits
    @usage_limit = @account.usage_limits.new
  end

  # GET /account/edit
  def edit
    authorize @account, :update?
  end

  # PATCH/PUT /account
  def update
    authorize @account, :update?

    if @account.update(account_params)
      redirect_to account_path, notice: "Account updated."
    else
      render :edit, status: :unprocessable_entity
    end
  end

  private

  def usage_limit_scope_label(scope)
    SCOPE_LABELS.fetch(scope.to_s, scope.to_s.humanize)
  end

  def set_account
    @account = current_account
  end

  # A user without an account has nothing to show; bail before authorization so
  # the halted chain skips verify_authorized rather than raising on a nil record.
  def require_account
    return if current_account.present?

    redirect_to root_path, alert: "Your login is not linked to an account yet."
  end

  # Only the two operational fields. webhook_secret, settings and parent_id are
  # operator concerns and must never be reachable from this form.
  def account_params
    params.require(:account).permit(:name, :default_callback_url)
  end

  # Caps set higher up the tree also bind this account, so they are shown here
  # read-only. Ancestor chains are at most Account::MAX_DEPTH deep.
  def inherited_limits
    ancestor_ids = @account.ancestors.map(&:id)
    return UsageLimit.none if ancestor_ids.empty?

    UsageLimit.where(account_id: ancestor_ids)
              .includes(:account)
              .order(:account_id, :metric, :period, :scope)
  end
end
