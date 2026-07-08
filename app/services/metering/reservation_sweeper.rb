module Metering
  # Releases stale in-flight (`pending`) usage_events so a hold that was never
  # finalized does not linger forever. A pending event is stale once its
  # `reserved_until` has passed, or — when `reserved_until` was never set —
  # after a fixed fallback age. Stale events are transitioned to :failed.
  #
  # Conservative + additive by design: it does NOT mutate credit balances.
  # Holds are postpaid (QuotaGuard.hold! does not decrement balance and
  # UsageRecorder writes :finalized events), so a swept pending event reserves
  # no budget to return. Refunding a swept event that was actually charged is a
  # deliberate follow-up — it must first confirm a matching deduction exists,
  # otherwise refund! would credit a charge that never happened.
  #
  # Safe to run repeatedly: only :pending rows are touched, so a second sweep
  # over the same window releases nothing. Wired as a Solid Queue recurring task
  # via Metering::ReservationSweeperJob (see config/recurring.yml).
  class ReservationSweeper
    # Fallback staleness age for pending events with no reserved_until set.
    DEFAULT_MAX_AGE = 1.hour

    def self.call(now: Time.current, max_age: DEFAULT_MAX_AGE)
      new(now: now, max_age: max_age).call
    end

    def initialize(now: Time.current, max_age: DEFAULT_MAX_AGE)
      @now = now
      @max_age = max_age
    end

    # Transitions stale pending events to :failed. Returns the number released.
    def call
      stale_events.update_all(status: "failed", updated_at: @now)
    end

    private

    def stale_events
      UsageEvent.where(status: "pending").where(
        "reserved_until < :now OR (reserved_until IS NULL AND created_at < :cutoff)",
        now: @now, cutoff: @now - @max_age
      )
    end
  end
end
