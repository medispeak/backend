# Runs the scribe pipeline for one session asynchronously (solid_queue in
# prod; the :inline adapter in test runs it synchronously).
#
# Flow:
#   1. Load the session (no-op if it was deleted/expired).
#   2. Move it to :processing.
#   3. Settle per-segment transcription: finish stragglers inline through the
#      segment job's atomic claim; if an async job still holds a claim,
#      RE-ENQUEUE this job with a short wait instead of blocking a worker
#      thread on a poll loop. The session stays :processing and the client
#      keeps polling.
#   4. Run Scribe::Orchestrator (which sets the final completed/partial/failed
#      status and fills the outputs + transcript).
#   5. If the session has a callback_url, enqueue ScribeWebhookJob to deliver the
#      PHI-light completion notification.
#
# Any unexpected error marks the session :failed with a sanitized message and is
# logged but NOT re-raised, so a poison job does not retry forever. Metering is
# best-effort (see Scribe::Orchestrator#meter); a usage_event left :pending is
# swept to :failed by Metering::ReservationSweeper rather than trued up against
# the ledger (holds are postpaid and reserve no credit balance).
class ProcessScribeSessionJob < ApplicationJob
  # Settlement waits ~2 minutes (matching STALE_CLAIM_AGE) for in-flight segment
  # jobs, then treats any remaining "transcribing" claim as a dead worker:
  # reclaim and retry inline exactly once before the orchestrator settles the
  # session.
  #
  # The wait is DELIBERATELY not flat. A client commits the instant the last
  # segment upload returns, so that segment's ASR (~0.5-2s) is nearly always
  # still in flight on the first attempt — and a flat 5s tick charged every
  # single commit a full tick of dead time before anything else could happen.
  # The first FAST_SETTLE_ATTEMPTS therefore retry on a 1s tick (the floor is
  # the dispatcher's own polling_interval, config/queue.yml), and only a
  # genuinely slow settlement backs off to the coarse tick. Attempt counts are
  # sized so the TOTAL budget still covers STALE_CLAIM_AGE:
  #   5 x 1s + 23 x 5s = 120s.
  FAST_SETTLE_ATTEMPTS = 5
  FAST_SETTLE_WAIT = 1.second
  MAX_SETTLE_ATTEMPTS = 28
  SETTLE_WAIT = 5.seconds
  STALE_CLAIM_AGE = 2.minutes

  # Backoff for the next settle retry: short while the racing segment is
  # plausibly still mid-call, coarse once waiting is clearly not paying off.
  def self.settle_wait_for(attempt)
    attempt < FAST_SETTLE_ATTEMPTS ? FAST_SETTLE_WAIT : SETTLE_WAIT
  end

  def perform(scribe_session_id, settle_attempt = 0)
    session = ScribeSession.find_by(id: scribe_session_id)
    return if session.nil?

    session.update!(status: :processing)

    return if settle_segments(session, settle_attempt) == :waiting

    Scribe::Orchestrator.new(session).call

    # Webhook delivery is best-effort and OUTSIDE the failure path below: an
    # enqueue error must not demote a session the orchestrator already finalized.
    enqueue_webhook(session)
  rescue StandardError => e
    # Only mark :failed when the pipeline did NOT already reach a terminal
    # status. The Orchestrator sets completed/partial/failed itself; a late error
    # (e.g. a metering/webhook hiccup after outputs persisted) must not demote an
    # already-successful session to :failed and hide a delivered result.
    if session && !session.reload.completed? && !session.partial?
      session.update(status: :failed, error: { message: e.message })
    end
    Rails.logger.error("ProcessScribeSessionJob failed for session=#{scribe_session_id}: #{e.class}: #{e.message}")
    nil
  end

  private

  # Brings every transcription segment to a settled status (done/failed) before
  # the orchestrator assembles the transcript. Returns :waiting when this job
  # re-enqueued itself to let an in-flight async segment job finish, :settled
  # otherwise.
  #
  # Never calls the provider directly — all transcription goes through
  # TranscribeSegmentJob's atomic pending/failed -> transcribing claim, so the
  # async on-arrival job and this commit-time pass can never double-call the
  # provider for one segment.
  def settle_segments(session, attempt)
    return :settled if session.transcript.present?

    segments = session.transcript_segments
    return :settled unless segments.exists?

    # Stragglers the async path never finished (or that failed): transcribe
    # inline through the same atomic claim (a no-op if an async job owns them).
    transcribe_inline(segments.where(status: %w[pending failed]))

    if segments.where(status: "transcribing").exists?
      if attempt < MAX_SETTLE_ATTEMPTS
        self.class.set(wait: self.class.settle_wait_for(attempt)).perform_later(session.id, attempt + 1)
        return :waiting
      end

      # Out of patience: a claim this old means the worker died mid-call.
      # Conditionally reclaim (the age guard spares a live-but-slow job) and
      # retry inline once; whatever is still unsettled after this is reported
      # by the orchestrator as an explicit per-segment failure.
      segments.where(status: "transcribing")
              .where(updated_at: ...STALE_CLAIM_AGE.ago)
              .update_all(status: "failed", updated_at: Time.current)
      transcribe_inline(segments.where(status: "failed"))
    end

    :settled
  end

  def transcribe_inline(scope)
    scope.pluck(:id).each { |id| TranscribeSegmentJob.perform_now(id) }
  end

  def enqueue_webhook(session)
    ScribeWebhookJob.perform_later(session.id) if session.callback_url.present?
  rescue StandardError => e
    Rails.logger.error("ScribeWebhookJob enqueue failed for session=#{session.id}: #{e.class}: #{e.message}")
  end
end
