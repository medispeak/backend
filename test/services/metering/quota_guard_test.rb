require "test_helper"

class MeteringQuotaGuardTest < ActiveSupport::TestCase
  test "hold succeeds and records a hold transaction when balance is sufficient" do
    account = create(:account)
    create(:account_credit, account: account, balance: 100)

    token = nil
    assert_difference("CreditTransaction.count", 1) do
      token = Metering::QuotaGuard.hold!(account: account, estimate: 10)
    end

    assert token.ok?
    refute token.unlimited?
    assert_equal "hold", token.transaction.txn_type
    assert_equal 10, token.transaction.amount.to_f
  end

  test "hold fails when balance is insufficient" do
    account = create(:account)
    create(:account_credit, account: account, balance: 5)

    token = nil
    assert_no_difference("CreditTransaction.count") do
      token = Metering::QuotaGuard.hold!(account: account, estimate: 10)
    end

    refute token.ok?
  end

  test "hold is a no-op unlimited token when no AccountCredit exists" do
    account = create(:account)

    token = nil
    assert_no_difference("CreditTransaction.count") do
      token = Metering::QuotaGuard.hold!(account: account, estimate: 9999)
    end

    assert token.ok?
    assert token.unlimited?
    assert_nil token.transaction
  end

  test "deduct decrements the balance and records a deduction" do
    account = create(:account)
    credit = create(:account_credit, account: account, balance: 100)
    event = create(:usage_event, account: account, cost: 12.5)

    assert_difference("CreditTransaction.count", 1) do
      Metering::QuotaGuard.deduct!(event)
    end

    assert_equal 87.5, credit.reload.balance.to_f
    txn = CreditTransaction.find_by(usage_event_id: event.id, txn_type: "deduction")
    assert_equal 100, txn.balance_before.to_f
    assert_equal 87.5, txn.balance_after.to_f
    assert_equal 12.5, txn.amount.to_f
  end

  test "deduct is idempotent under retry via the unique constraint" do
    account = create(:account)
    credit = create(:account_credit, account: account, balance: 100)
    event = create(:usage_event, account: account, cost: 10)

    Metering::QuotaGuard.deduct!(event)
    # A retried finalize must not double-charge.
    second = Metering::QuotaGuard.deduct!(event)

    assert_nil second
    assert_equal 1, CreditTransaction.where(usage_event_id: event.id, txn_type: "deduction").count
    assert_equal 90, credit.reload.balance.to_f
  end

  test "refund increments the balance and records a refund" do
    account = create(:account)
    credit = create(:account_credit, account: account, balance: 50)
    event = create(:usage_event, account: account, cost: 7)

    assert_difference("CreditTransaction.count", 1) do
      Metering::QuotaGuard.refund!(event)
    end

    assert_equal 57, credit.reload.balance.to_f
    txn = CreditTransaction.find_by(usage_event_id: event.id, txn_type: "refund")
    assert_equal 50, txn.balance_before.to_f
    assert_equal 57, txn.balance_after.to_f
  end

  test "deduct no-ops gracefully when no AccountCredit exists" do
    account = create(:account)
    event = create(:usage_event, account: account, cost: 10)

    result = nil
    assert_no_difference("CreditTransaction.count") do
      result = Metering::QuotaGuard.deduct!(event)
    end

    assert_nil result
  end

  test "refund no-ops gracefully when no AccountCredit exists" do
    account = create(:account)
    event = create(:usage_event, account: account, cost: 10)

    result = nil
    assert_no_difference("CreditTransaction.count") do
      result = Metering::QuotaGuard.refund!(event)
    end

    assert_nil result
  end

  test "deduct and refund can coexist for the same usage_event (distinct txn_types)" do
    account = create(:account)
    credit = create(:account_credit, account: account, balance: 100)
    event = create(:usage_event, account: account, cost: 10)

    Metering::QuotaGuard.deduct!(event)
    Metering::QuotaGuard.refund!(event)

    assert_equal 100, credit.reload.balance.to_f
    assert_equal 1, CreditTransaction.where(usage_event_id: event.id, txn_type: "deduction").count
    assert_equal 1, CreditTransaction.where(usage_event_id: event.id, txn_type: "refund").count
  end
end
