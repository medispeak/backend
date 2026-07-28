require "test_helper"

# Caps are nested under the singular `resource :account`, so there is no
# account_id in the URL and none is accepted from the body: every write goes
# through current_account. These tests pin that down.
class UsageLimitsControllerTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers

  setup do
    @user = create(:user)
    @account = @user.account

    @other_account = create(:account, name: "Northgate Hospital")
    @other_limit = create(:usage_limit, account: @other_account, metric: "cost", period: "monthly")
  end

  # --------------------------------------------------------------- auth gate

  test "create redirects to sign in when signed out" do
    assert_no_difference "UsageLimit.count" do
      post account_usage_limits_path, params: { usage_limit: valid_params }
    end
    assert_redirected_to new_user_session_path
  end

  test "destroy redirects to sign in when signed out" do
    limit = create(:usage_limit, account: @account)

    assert_no_difference "UsageLimit.count" do
      delete account_usage_limit_path(limit)
    end
    assert_redirected_to new_user_session_path
  end

  # -------------------------------------------------------------- happy path

  test "create adds a cap to the signed-in user's account" do
    sign_in @user

    assert_difference "UsageLimit.count", 1 do
      post account_usage_limits_path, params: { usage_limit: valid_params }
    end

    assert_redirected_to account_path
    assert_equal "Spending cap added.", flash[:notice]

    limit = UsageLimit.order(:id).last
    assert_equal @account, limit.account
    assert_equal "subtree", limit.scope
    assert_equal "cost", limit.metric
    assert_equal "monthly", limit.period
    assert_equal 250, limit.limit_value
  end

  test "destroy removes the account's own cap" do
    limit = create(:usage_limit, account: @account)
    sign_in @user

    assert_difference "UsageLimit.count", -1 do
      delete account_usage_limit_path(limit)
    end

    assert_redirected_to account_path
    assert_equal "Spending cap removed.", flash[:notice]
    assert_nil UsageLimit.find_by(id: limit.id)
  end

  # ------------------------------------------------------------- bad input

  test "create reports a readable error when the value is not positive" do
    sign_in @user

    assert_no_difference "UsageLimit.count" do
      post account_usage_limits_path, params: { usage_limit: valid_params(limit_value: 0) }
    end

    assert_redirected_to account_path
    # config/locales/en.yml renames usage_limit.limit_value to "Limit", so the
    # sentence reads "limit must be greater than 0" — never "limit value".
    assert_match(/limit must be greater than 0/i, flash[:alert])
  end

  test "create rejects an unknown scope" do
    sign_in @user

    assert_no_difference "UsageLimit.count" do
      post account_usage_limits_path, params: { usage_limit: valid_params(scope: "everything") }
    end

    assert_redirected_to account_path
    assert flash[:alert].present?
  end

  test "create explains that a cap for that metric and period already exists" do
    create(:usage_limit, account: @account, scope: "subtree", metric: "cost", period: "monthly")
    sign_in @user

    assert_no_difference "UsageLimit.count" do
      post account_usage_limits_path, params: { usage_limit: valid_params }
    end

    assert_redirected_to account_path
    assert_match(/already exists/, flash[:alert])
  end

  test "destroy of a cap that is already gone reports it instead of erroring" do
    limit = create(:usage_limit, account: @account)
    id = limit.id
    limit.destroy!
    sign_in @user

    delete account_usage_limit_path(id)

    assert_redirected_to account_path
    assert_match(/no longer exists/, flash[:alert])
  end

  # ---------------------------------------------------------- tenancy safety

  test "create ignores an account_id in the body and writes to the signed-in account" do
    sign_in @user

    assert_difference "UsageLimit.count", 1 do
      post account_usage_limits_path,
           params: { usage_limit: valid_params.merge(account_id: @other_account.id) }
    end

    limit = UsageLimit.order(:id).last
    assert_equal @account, limit.account
    assert_equal 1, @other_account.usage_limits.count
  end

  test "destroy cannot remove another account's cap" do
    sign_in @user

    assert_no_difference "UsageLimit.count" do
      delete account_usage_limit_path(@other_limit)
    end

    assert_redirected_to account_path
    assert_match(/no longer exists/, flash[:alert])
    assert UsageLimit.exists?(@other_limit.id)
  end

  private

  def valid_params(overrides = {})
    { scope: "subtree", metric: "cost", period: "monthly", limit_value: 250 }.merge(overrides)
  end
end
