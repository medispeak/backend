require "test_helper"

class UsageControllerTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers

  setup do
    @user = create(:user)
    @account = @user.account
  end

  test "requires a signed-in user" do
    get usage_path

    assert_redirected_to new_user_session_path
  end

  test "reports the account's finalized usage for the current month" do
    create(:usage_event, account: @account, user: @user, function: "asr",
                         provider: "openai", model: "whisper-1",
                         audio_seconds: 120, cost: 0.5)
    create(:usage_event, account: @account, user: @user, function: "structuring",
                         provider: "openai", model: "gpt-4o-mini",
                         total_tokens: 1_500, cost: 0.25)
    create(:scribe_session, account: @account, user: @user)
    sign_in @user

    get usage_path

    assert_response :success
    # Stat cards: $0.75 spent, 1,500 tokens, 2 minutes of audio.
    assert_match "$0.75", response.body
    assert_match "1,500", response.body
    # By capability and by model.
    assert_match "Transcription", response.body
    assert_match "Structuring", response.body
    assert_match "whisper-1", response.body
    assert_match "gpt-4o-mini", response.body
  end

  test "excludes usage belonging to another account" do
    other_account = create(:account)
    create(:usage_event, account: other_account, model: "rival-model", cost: 99)
    create(:usage_event, account: @account, user: @user, model: "gpt-4o-mini", cost: 1)
    sign_in @user

    get usage_path

    assert_response :success
    assert_no_match(/rival-model/, response.body)
    assert_no_match(/\$99\.00/, response.body)
  end

  test "pending and failed events are left out of the report" do
    create(:usage_event, account: @account, user: @user, status: "pending",
                         model: "pending-model", cost: 5)
    create(:usage_event, account: @account, user: @user, status: "failed",
                         model: "failed-model", cost: 7)
    sign_in @user

    get usage_path

    assert_response :success
    assert_no_match(/pending-model/, response.body)
    assert_no_match(/failed-model/, response.body)
    assert_match "Nothing metered in this period", response.body
  end

  test "an unknown period falls back to this month" do
    create(:usage_event, account: @account, user: @user, model: "old-model",
                         cost: 3, created_at: 2.months.ago)
    create(:usage_event, account: @account, user: @user, model: "current-model", cost: 1)
    sign_in @user

    get usage_path(period: "everything")

    assert_response :success
    assert_match "current-model", response.body
    assert_no_match(/old-model/, response.body)
  end

  test "all time includes usage from earlier periods" do
    create(:usage_event, account: @account, user: @user, model: "old-model",
                         cost: 3, created_at: 2.months.ago)
    sign_in @user

    get usage_path(period: "all")

    assert_response :success
    assert_match "old-model", response.body
  end

  test "week narrows the report to the calendar week" do
    travel_to Time.zone.local(2026, 3, 12, 10, 0) do
      create(:usage_event, account: @account, user: @user, model: "this-week-model",
                           cost: 1, created_at: Time.zone.local(2026, 3, 9, 9, 0))
      create(:usage_event, account: @account, user: @user, model: "last-week-model",
                           cost: 2, created_at: Time.zone.local(2026, 3, 3, 9, 0))
      sign_in @user

      get usage_path(period: "week")

      assert_response :success
      assert_match "this-week-model", response.body
      assert_no_match(/last-week-model/, response.body)
    end
  end

  test "the per-user table appears only once the account has more than one user" do
    create(:usage_event, account: @account, user: @user, model: "gpt-4o-mini", cost: 1)
    sign_in @user

    get usage_path

    assert_response :success
    assert_no_match(/By user/, response.body)

    colleague = create(:user, account: @account)
    create(:usage_event, account: @account, user: colleague, model: "gpt-4o-mini", cost: 2)

    get usage_path

    assert_response :success
    assert_match "By user", response.body
    assert_match colleague.email, response.body
  end

  test "shows usage against the account's own and its ancestors' limits" do
    parent = create(:account)
    @account.update!(parent: parent)
    create(:usage_limit, account: @account, scope: "subtree", metric: "cost",
                         period: "monthly", limit_value: 10)
    create(:usage_limit, account: parent, scope: "subtree", metric: "tokens",
                         period: "daily", limit_value: 1_000)
    # A pending event still counts against a cap, exactly as LimitGuard admits.
    create(:usage_event, account: @account, user: @user, status: "pending",
                         total_tokens: 250, cost: 2.5)
    sign_in @user

    get usage_path

    assert_response :success
    assert_match "of $10.00", response.body
    assert_match "of 1,000", response.body
    assert_match "$2.50", response.body
    assert_match "Everything under #{parent.name}", response.body
  end

  test "a user whose account was deleted is redirected instead of 500ing" do
    # Account has_many :users, dependent: :nullify — deleting an account leaves
    # its users with no account at all.
    @user.update_column(:account_id, nil)
    sign_in @user

    get usage_path

    assert_redirected_to root_path
  end

  test "says usage is uncapped when no limits apply" do
    sign_in @user

    get usage_path

    assert_response :success
    assert_match "usage is uncapped", response.body
  end
end
