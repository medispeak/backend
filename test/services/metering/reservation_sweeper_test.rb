require "test_helper"

class MeteringReservationSweeperTest < ActiveSupport::TestCase
  test "sweeps a pending usage_event whose reserved_until has passed to failed" do
    account = create(:account)
    event = create(:usage_event, account: account, status: "pending", reserved_until: 5.minutes.ago)

    assert_equal 1, Metering::ReservationSweeper.call
    assert_equal "failed", event.reload.status
  end

  test "sweeps a pending usage_event with no reserved_until once older than the max age" do
    account = create(:account)
    event = create(:usage_event, account: account, status: "pending",
                                 reserved_until: nil, created_at: 2.hours.ago)

    assert_equal 1, Metering::ReservationSweeper.call
    assert_equal "failed", event.reload.status
  end

  test "leaves fresh pending events and finalized events untouched" do
    account = create(:account)
    fresh = create(:usage_event, account: account, status: "pending", reserved_until: 5.minutes.from_now)
    recent_null = create(:usage_event, account: account, status: "pending",
                                       reserved_until: nil, created_at: 1.minute.ago)
    finalized = create(:usage_event, account: account, status: "finalized", reserved_until: 5.minutes.ago)

    assert_equal 0, Metering::ReservationSweeper.call
    assert_equal "pending", fresh.reload.status
    assert_equal "pending", recent_null.reload.status
    assert_equal "finalized", finalized.reload.status
  end

  test "is idempotent — a second sweep releases nothing and does not mutate balances" do
    account = create(:account)
    credit = create(:account_credit, account: account, balance: 25)
    create(:usage_event, account: account, status: "pending", reserved_until: 5.minutes.ago)

    assert_equal 1, Metering::ReservationSweeper.call
    assert_equal 0, Metering::ReservationSweeper.call
    # Conservative + additive: sweeping never touches the credit ledger.
    assert_equal 25.0, credit.reload.balance.to_f
  end
end
