require "test_helper"

# The account surface is a singular resource: it always resolves to
# current_account, so the tenancy assertions here are about what the page can
# be made to *show*, not about which id can be fetched.
class AccountsControllerTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers

  setup do
    @user = create(:user)
    @account = @user.account
    @account.update!(name: "Riverside Clinic")

    # A completely separate tenant that must never leak into the page.
    @other_account = create(:account, name: "Northgate Hospital")
    @other_user = create(:user)
    @other_user.update!(account: @other_account, email: "intruder@example.com")
    @other_limit = create(:usage_limit, account: @other_account, metric: "tokens", period: "daily")
  end

  # --------------------------------------------------------------- auth gate

  test "show redirects to sign in when signed out" do
    get account_path
    assert_redirected_to new_user_session_path
  end

  test "edit redirects to sign in when signed out" do
    get edit_account_path
    assert_redirected_to new_user_session_path
  end

  test "update redirects to sign in when signed out" do
    patch account_path, params: { account: { name: "Hijacked" } }
    assert_redirected_to new_user_session_path
    assert_equal "Riverside Clinic", @account.reload.name
  end

  # -------------------------------------------------------------- happy path

  test "show renders the account, its team and its caps" do
    limit = create(:usage_limit, account: @account, scope: "subtree", metric: "cost", period: "monthly",
                                 limit_value: 250)
    create(:account_credit, account: @account, balance: 42)

    sign_in @user
    get account_path

    assert_response :success
    assert_select "h1", "Account"
    assert_match "Riverside Clinic", response.body
    assert_match @user.email, response.body
    assert_match "$42.00", response.body
    assert_match account_usage_limit_path(limit), response.body
  end

  test "show states that spending is uncapped when no credit record exists" do
    sign_in @user
    get account_path

    assert_response :success
    assert_match "No prepaid balance is held", response.body
  end

  test "show describes a standalone account instead of drawing an empty tree" do
    sign_in @user
    get account_path

    assert_response :success
    assert_match "standalone account", response.body
  end

  test "show renders the tenancy breadcrumb and children for a nested account" do
    parent = create(:account, name: "Regional Trust")
    @account.update!(parent: parent)
    child = create(:account, name: "Riverside Annexe", parent: @account)

    sign_in @user
    get account_path

    assert_response :success
    assert_match "Regional Trust", response.body
    assert_match child.name, response.body
    assert_no_match(/standalone account/, response.body)
  end

  test "show lists ancestor caps as inherited and without a remove control" do
    parent = create(:account, name: "Regional Trust")
    @account.update!(parent: parent)
    inherited = create(:usage_limit, account: parent, metric: "cost", period: "monthly")

    sign_in @user
    get account_path

    assert_response :success
    assert_match "Regional Trust", response.body
    assert_match "Inherited", response.body
    assert_no_match(/#{Regexp.escape(account_usage_limit_path(inherited))}/, response.body)
  end

  test "edit renders the form" do
    sign_in @user
    get edit_account_path

    assert_response :success
    assert_select "input[name=?]", "account[name]"
    assert_select "input[name=?]", "account[default_callback_url]"
  end

  test "update saves the name and callback url" do
    sign_in @user
    patch account_path, params: {
      account: { name: "Riverside Clinic North", default_callback_url: "https://hooks.example.com/medispeak" }
    }

    assert_redirected_to account_path
    @account.reload
    assert_equal "Riverside Clinic North", @account.name
    assert_equal "https://hooks.example.com/medispeak", @account.default_callback_url
  end

  test "update re-renders with an error when the name is blank" do
    sign_in @user
    patch account_path, params: { account: { name: "" } }

    assert_response :unprocessable_entity
    assert_equal "Riverside Clinic", @account.reload.name
  end

  # ---------------------------------------------------------- tenancy safety

  test "update ignores operator-only attributes" do
    original_secret = @account.webhook_secret

    sign_in @user
    patch account_path, params: {
      account: {
        name: "Riverside Clinic",
        parent_id: @other_account.id,
        webhook_secret: "leaked",
        settings: { "spoofed" => true }
      }
    }

    @account.reload
    assert_nil @account.parent_id
    assert_equal original_secret, @account.webhook_secret
    assert_equal({}, @account.settings)
  end

  test "show never exposes another account's name, people or caps" do
    sign_in @user
    get account_path

    assert_response :success
    assert_no_match(/Northgate Hospital/, response.body)
    assert_no_match(/intruder@example.com/, response.body)
    assert_no_match(/#{Regexp.escape(account_usage_limit_path(@other_limit))}/, response.body)
  end

  test "a user always sees their own account, never the last one created" do
    sign_in @other_user
    get account_path

    assert_response :success
    assert_match "Northgate Hospital", response.body
    assert_no_match(/Riverside Clinic/, response.body)
  end
end
