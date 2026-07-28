require "test_helper"

# The Overview is the first screen after sign-in, so it has to be private,
# render for a real account, and never leak another account's activity.
class DashboardControllerTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers

  setup do
    @user = create(:user)
    @account = @user.account

    @other_user = create(:user)
    @other_account = @other_user.account
  end

  test "redirects to sign in when signed out" do
    get root_path

    assert_redirected_to new_user_session_path
  end

  test "renders for a signed-in user" do
    sign_in(@user)

    get root_path

    assert_response :success
    assert_select "h1", text: "Overview"
    assert_select ".stat-label", text: "Consultations"
    assert_select ".stat-label", text: "Transcription"
    assert_select ".stat-label", text: "Spend"
  end

  test "shows this month's consultations, minutes and finalized spend" do
    create(:scribe_session, account: @account, user: @user, status: "completed")
    create(:scribe_session, account: @account, user: @user, status: "processing")
    create(:usage_event, account: @account, function: "asr", audio_seconds: 180, cost: 1.25)
    # Pending events are not yet a charge, so they must not appear in spend.
    create(:usage_event, account: @account, status: "pending", cost: 99)

    sign_in(@user)
    get root_path

    assert_response :success
    assert_select ".stat-value", text: /\A2\z/
    assert_select ".stat-value", text: /3\s*min/ # 180 audio seconds -> 3 min
    assert_select ".stat-value", text: /\$1\.25/
    assert_no_match(/\$99\.00/, response.body)
  end

  test "lists recent consultations with a link to each session" do
    session = create(:scribe_session, account: @account, user: @user, status: "completed")
    create(:scribe_output, scribe_session: session, status: "success")

    sign_in(@user)
    get root_path

    assert_response :success
    assert_select "a[href=?]", scribe_session_path(session), text: "##{session.id}"
    assert_select ".badge", text: "Completed"
  end

  test "shows at most the eight most recent consultations" do
    sessions = 10.times.map do |i|
      create(:scribe_session, account: @account, user: @user, created_at: i.minutes.ago)
    end

    sign_in(@user)
    get root_path

    assert_response :success
    assert_select "a[href=?]", scribe_session_path(sessions.first)
    assert_select "a[href=?]", scribe_session_path(sessions.last), count: 0
  end

  test "does not show another account's consultations or spend" do
    mine = create(:scribe_session, account: @account, user: @user)
    theirs = create(:scribe_session, account: @other_account, user: @other_user)
    create(:usage_event, account: @other_account, cost: 77, audio_seconds: 6000)

    sign_in(@user)
    get root_path

    assert_response :success
    assert_select "a[href=?]", scribe_session_path(mine)
    assert_select "a[href=?]", scribe_session_path(theirs), count: 0
    assert_no_match(/\$77\.00/, response.body)
  end

  test "omits the credit card when the account has no credit" do
    sign_in(@user)

    get root_path

    assert_response :success
    assert_select ".stat-label", text: "Credit balance", count: 0
  end

  test "shows the credit balance when the account is on credit" do
    create(:account_credit, account: @account, balance: 42)

    sign_in(@user)
    get root_path

    assert_response :success
    assert_select ".stat-label", text: "Credit balance"
    assert_match "$42.00", response.body
  end

  test "shows getting started only when there are no sessions and no api keys" do
    sign_in(@user)

    get root_path

    assert_response :success
    assert_select "h2", text: "Getting started"
    assert_select "a[href=?]", new_api_token_path
  end

  test "hides getting started once an api key exists" do
    create(:api_token, user: @user)

    sign_in(@user)
    get root_path

    assert_response :success
    assert_select "h2", text: "Getting started", count: 0
  end

  test "hides getting started once a session exists" do
    create(:scribe_session, account: @account, user: @user)

    sign_in(@user)
    get root_path

    assert_response :success
    assert_select "h2", text: "Getting started", count: 0
  end

  # Account has_many :users, dependent: :nullify, and AccountsController
  # redirects an accountless user to the root path — so the Overview is where
  # that state lands and must not raise on `authorize nil`.
  test "renders a message when the login has no account" do
    @user.update_column(:account_id, nil)

    sign_in(@user)
    get root_path

    assert_response :success
    assert_select "h3", text: "Your login is not linked to an account"
    assert_select ".stat-label", count: 0
  end

  test "empty state points at the API keys page" do
    sign_in(@user)

    get root_path

    assert_response :success
    assert_select "h3", text: "No consultations yet"
    assert_select "a[href=?]", new_api_token_path, text: "Create an API key"
  end
end
