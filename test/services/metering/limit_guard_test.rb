require "test_helper"

# Pure-read admission gate over usage_events: subtree/per_user × tokens/cost ×
# daily/monthly, all limits on the leaf-to-root chain must pass.
class MeteringLimitGuardTest < ActiveSupport::TestCase
  setup do
    @org = create(:account, name: "Org")
    @facility = create(:account, name: "Facility", parent: @org)
    @user = create(:user, account: @facility)
  end

  def check(account: @facility, user: @user, estimated_cost: 0)
    Metering::LimitGuard.check(account: account, user: user, estimated_cost: estimated_cost)
  end

  def event(account:, user: nil, tokens: 0, cost: 0, status: "finalized", at: Time.current)
    create(:usage_event, account: account, user_id: user&.id,
           total_tokens: tokens, cost: cost, status: status, created_at: at)
  end

  test "no limits anywhere on the chain means unlimited" do
    event(account: @facility, user: @user, tokens: 1_000_000)
    assert check.ok?
  end

  test "a per_user daily token cap blocks once the user reaches it" do
    create(:usage_limit, account: @org, scope: "per_user", metric: "tokens",
           period: "daily", limit_value: 1000)

    event(account: @facility, user: @user, tokens: 999)
    assert check.ok?, "under the cap must pass"

    event(account: @facility, user: @user, tokens: 1)
    result = check
    assert_not result.ok?, "at the cap must block"
    assert_equal "per_user", result.violation.limit.scope
    assert_equal 1000, result.violation.used.to_i
  end

  test "a daily cap resets across the day boundary" do
    create(:usage_limit, account: @facility, scope: "per_user", metric: "tokens",
           period: "daily", limit_value: 100)
    event(account: @facility, user: @user, tokens: 500, at: 2.days.ago)

    assert check.ok?, "yesterday's usage must not count against today's window"
  end

  test "a subtree monthly cost budget aggregates the whole subtree" do
    create(:usage_limit, account: @org, scope: "subtree", metric: "cost",
           period: "monthly", limit_value: 10)
    sibling = create(:account, name: "Facility B", parent: @org)

    event(account: @facility, cost: 6)
    event(account: sibling, cost: 4)

    result = check
    assert_not result.ok?, "6 + 4 across the subtree reaches the 10 budget"
    assert_equal "subtree", result.violation.limit.scope
  end

  test "an estimated cost that would cross the budget blocks pre-flight" do
    create(:usage_limit, account: @org, scope: "subtree", metric: "cost",
           period: "monthly", limit_value: 10)
    event(account: @facility, cost: 8)

    assert check(estimated_cost: 1).ok?
    assert_not check(estimated_cost: 2).ok?
  end

  test "limits at different nodes compose — all must pass" do
    create(:usage_limit, account: @org, scope: "subtree", metric: "cost",
           period: "monthly", limit_value: 1000)
    create(:usage_limit, account: @facility, scope: "per_user", metric: "tokens",
           period: "daily", limit_value: 10)

    event(account: @facility, user: @user, tokens: 10)

    result = check
    assert_not result.ok?, "the generous org budget passes but the facility per-user cap blocks"
    assert_equal "per_user", result.violation.limit.scope
  end

  test "a nil user skips per_user limits but subtree limits still guard" do
    create(:usage_limit, account: @org, scope: "per_user", metric: "tokens",
           period: "daily", limit_value: 1)
    event(account: @facility, user: @user, tokens: 100)

    assert check(user: nil).ok?, "per_user cannot apply without a user"

    create(:usage_limit, account: @org, scope: "subtree", metric: "tokens",
           period: "daily", limit_value: 50)
    assert_not check(user: nil).ok?
  end

  test "pending events count toward the window; failed events do not" do
    create(:usage_limit, account: @facility, scope: "per_user", metric: "tokens",
           period: "daily", limit_value: 100)

    event(account: @facility, user: @user, tokens: 100, status: "failed")
    assert check.ok?, "failed events must not consume budget"

    event(account: @facility, user: @user, tokens: 100, status: "pending")
    assert_not check.ok?, "in-flight (pending) events must consume budget"
  end

  test "per_user caps follow the user across facilities (no reset by moving)" do
    create(:usage_limit, account: @org, scope: "per_user", metric: "tokens",
           period: "daily", limit_value: 100)
    other_facility = create(:account, name: "Facility B", parent: @org)
    event(account: other_facility, user: @user, tokens: 100)

    assert_not check(account: @facility).ok?,
           "usage recorded at another facility still counts against the same user"
  end
end
