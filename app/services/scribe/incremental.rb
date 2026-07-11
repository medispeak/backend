module Scribe
  # Toggle for the incremental per-segment transcription path (plan 022).
  # OFF by default: the POST audio/segments endpoint 404s and commit uses the
  # whole-file ASR path. Flip with ENV["SCRIBE_INCREMENTAL_ASR"] = "true" (or
  # swap this predicate body for an account/system setting later without
  # touching the single call site in the controller).
  module Incremental
    def self.enabled?
      ActiveModel::Type::Boolean.new.cast(ENV["SCRIBE_INCREMENTAL_ASR"])
    end

    # Live form-fill: structure the growing transcript DURING recording so the
    # form is pre-filled by the time the clinician stops. OFF by default — it
    # runs extra structuring calls while recording. These interim passes are
    # NOT persisted or metered (the operator absorbs the small provider cost);
    # the authoritative, metered fill still happens once at commit. Flip with
    # ENV["SCRIBE_LIVE_FORM"] = "true". Requires the incremental path.
    def self.live_form_enabled?
      enabled? && ActiveModel::Type::Boolean.new.cast(ENV["SCRIBE_LIVE_FORM"])
    end
  end
end
