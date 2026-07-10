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
  end
end
