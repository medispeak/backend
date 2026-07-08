module Metering
  # Thin Solid Queue entry point for the recurring reservation sweep. Scheduled
  # in config/recurring.yml; delegates to Metering::ReservationSweeper, which
  # releases stale :pending usage_events. Kept trivial so the schedule config
  # points at a stable class name.
  class ReservationSweeperJob < ApplicationJob
    queue_as :background

    def perform
      Metering::ReservationSweeper.call
    end
  end
end
