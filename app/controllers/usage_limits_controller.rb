# Spending caps for the signed-in user's own account. Nested under the singular
# `resource :account`, so there is no account_id in params — and there must not
# be: every row is created and destroyed through `current_account`, which is
# what keeps one tenant from editing another tenant's caps.
class UsageLimitsController < ApplicationController
  before_action :require_account

  SCOPE_LABELS = {
    "subtree" => "whole-account",
    "per_user" => "per-user"
  }.freeze

  # POST /account/usage_limits
  def create
    @usage_limit = current_account.usage_limits.new(usage_limit_params)
    authorize @usage_limit

    if @usage_limit.save
      redirect_to account_path, notice: "Spending cap added."
    else
      redirect_to account_path, alert: creation_error_message(@usage_limit)
    end
  rescue ActiveRecord::RecordNotUnique
    # The (account, scope, metric, period) unique index caught a duplicate that
    # the validation missed because two requests raced.
    redirect_to account_path, alert: duplicate_message(@usage_limit)
  end

  # DELETE /account/usage_limits/:id
  def destroy
    usage_limit = current_account.usage_limits.find_by(id: params[:id])

    if usage_limit.nil?
      # Either already gone or belongs to another account. Same answer for both:
      # authorize the account so the Pundit guard still runs on a real record.
      authorize current_account, :manage_limits?
      return redirect_to account_path, alert: "That spending cap no longer exists."
    end

    authorize usage_limit
    usage_limit.destroy
    redirect_to account_path, notice: "Spending cap removed."
  end

  private

  def require_account
    return if current_account.present?

    redirect_to root_path, alert: "Your login is not linked to an account yet."
  end

  def usage_limit_params
    params.require(:usage_limit).permit(:scope, :metric, :period, :limit_value)
  end

  # "Scope has already been taken" is true but unreadable, so the collision gets
  # its own sentence naming the cap the user already has.
  def creation_error_message(limit)
    return duplicate_message(limit) if limit.errors.of_kind?(:scope, :taken)

    "Cap not added: #{limit.errors.full_messages.to_sentence.downcase}."
  end

  def duplicate_message(limit)
    scope = SCOPE_LABELS.fetch(limit.scope, limit.scope.to_s)
    "A #{scope} #{limit.period} cap on #{limit.metric} already exists. " \
      "Remove it before setting a new value."
  end
end
