module Metering
  # The dedupe_key format is a contract with the unique index behind
  # usage_events: one physical provider attempt gets exactly one key, so a
  # retried write collides instead of billing twice, and a genuinely new attempt
  # does NOT collide (which would leave real spend unbilled). Both the
  # whole-session path (Scribe::Orchestrator) and the per-segment path
  # (TranscribeSegmentJob) build keys here so the rule cannot drift between them.
  module DedupeKey
    class << self
      # Attempt 0 keeps the bare key it has always had, so a session already in
      # flight when attempt-scoping shipped keeps deduping against its own
      # earlier rows rather than being billed twice across the deploy.
      def suffixed(base, attempt)
        attempt.to_i.zero? ? base : "#{base}:#{attempt.to_i}"
      end

      def segment(session_id, segment_id, attempt)
        suffixed("#{session_id}:segment:#{segment_id}:asr", attempt)
      end
    end
  end
end
