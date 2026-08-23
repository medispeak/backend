require "test_helper"

class UsageEventTest < ActiveSupport::TestCase
  test "valid with required attributes" do
    assert build(:usage_event).valid?
  end

  test "requires a function" do
    assert_not build(:usage_event, function: nil).valid?
  end

  test "requires a status" do
    event = build(:usage_event)
    event.status = nil
    assert_not event.valid?
  end

  test "belongs to an account" do
    assert_not build(:usage_event, account: nil).valid?
  end

  test "api_token is optional" do
    assert build(:usage_event, api_token: nil).valid?
  end

  test "exposes function enum values" do
    assert_equal %w[asr structuring ocr], UsageEvent.functions.keys
  end

  test "exposes status enum values" do
    assert_equal %w[pending finalized failed], UsageEvent.statuses.keys
  end

  test "function enum predicates work" do
    event = build(:usage_event, function: "asr")
    assert event.asr?
    assert_not event.structuring?
  end

  test "status enum predicates work" do
    event = build(:usage_event, status: "pending")
    assert event.pending?
    assert_not event.finalized?
  end

  test "rejects an unknown function" do
    assert_raises(ArgumentError) { build(:usage_event, function: "bogus") }
  end

  test "a duplicate dedupe_key collides for a token-scoped session" do
    token = create(:api_token)
    create(:usage_event, api_token: token, dedupe_key: "1:asr")

    assert_raises(ActiveRecord::RecordNotUnique) do
      create(:usage_event, api_token: token, dedupe_key: "1:asr")
    end
  end

  # Every playground session records usage with no api_token. While the unique
  # index led with api_token_id, Postgres treated each NULL token as distinct
  # and enforced nothing here, so a redelivered job inserted a second event and
  # QuotaGuard deducted twice.
  test "a duplicate dedupe_key collides when there is no api_token" do
    create(:usage_event, api_token: nil, dedupe_key: "1:asr")

    assert_raises(ActiveRecord::RecordNotUnique) do
      create(:usage_event, api_token: nil, dedupe_key: "1:asr")
    end
  end

  test "events without a dedupe_key are not constrained" do
    create(:usage_event, api_token: nil, dedupe_key: nil)

    assert_nothing_raised { create(:usage_event, api_token: nil, dedupe_key: nil) }
  end
end
