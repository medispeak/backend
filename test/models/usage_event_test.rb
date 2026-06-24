require "test_helper"

class UsageEventTest < ActiveSupport::TestCase
  test "valid with required attributes" do
    assert build(:usage_event).valid?
  end

  test "requires a function" do
    refute build(:usage_event, function: nil).valid?
  end

  test "requires a status" do
    event = build(:usage_event)
    event.status = nil
    refute event.valid?
  end

  test "belongs to an account" do
    refute build(:usage_event, account: nil).valid?
  end

  test "api_token is optional" do
    assert build(:usage_event, api_token: nil).valid?
  end

  test "exposes function enum values" do
    assert_equal %w[asr structuring combined], UsageEvent.functions.keys
  end

  test "exposes status enum values" do
    assert_equal %w[pending finalized failed], UsageEvent.statuses.keys
  end

  test "function enum predicates work" do
    event = build(:usage_event, function: "asr")
    assert event.asr?
    refute event.structuring?
  end

  test "status enum predicates work" do
    event = build(:usage_event, status: "pending")
    assert event.pending?
    refute event.finalized?
  end

  test "rejects an unknown function" do
    assert_raises(ArgumentError) { build(:usage_event, function: "bogus") }
  end
end
