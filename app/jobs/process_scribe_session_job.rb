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
  # Settlement waits for in-flight segment jobs, then treats any remaining
  # "transcribing" claim as a dead worker: reclaim and retry inline exactly once
  # before the orchestrator settles the session.
  #
  # The wait is DELIBERATELY not flat. A client commits the instant the last
  # segment upload returns, so that segment's ASR (~0.5-2s) is nearly always
  # still in flight on the first attempt — and a flat 5s tick charged every
  # single commit a full tick of dead time before anything else could happen.
  # The first FAST_SETTLE_ATTEMPTS therefore retry on a 1s tick (the floor is
  # the dispatcher's own polling_interval, config/queue.yml), and only a
  # genuinely slow settlement backs off to the coarse tick:
  #   5 x 1s + 30 x 10s = 305s.
  #
  # STALE_CLAIM_AGE must stay ABOVE the worst-case provider call — the default
  # request_timeout is 120s and Llm::Caller may spend that twice before its
  # fallback answers — or a slow-but-alive job gets reclaimed and the segment is
  # transcribed (and billed) twice. The settle budget covers that age so a
  # genuinely dead worker is still reclaimed rather than falling through to the
  # whole-file pass.
  FAST_SETTLE_ATTEMPTS = 5
  FAST_SETTLE_WAIT = 1.second
  MAX_SETTLE_ATTEMPTS = 35
  SETTLE_WAIT = 10.seconds
  STALE_CLAIM_AGE = 5.minutes

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

      # Out of patience: a claim older than any possible provider call means the
      # worker died mid-call. Bumping `attempt` is what makes the reclaim safe —
      # it revokes the dead run's claim (its writes are scoped to the attempt it
      # took) and gives the retry its own dedupe key, so if the original was
      # merely slow both calls are billed instead of one silently colliding.
      # Whatever is still unsettled after this is reported by the orchestrator
      # as an explicit per-segment failure.
      segments.where(status: "transcribing")
              .where(updated_at: ...STALE_CLAIM_AGE.ago)
              .update_all("status = 'failed', attempt = attempt + 1, updated_at = NOW()")
      transcribe_inline(segments.where(status: "failed"))
    end

    :settled
  end

  def transcribe_inline(scope)
    scope.pluck(:id).each { |id| TranscribeSegmentJob.perform_now(id) }
  end

  # The delivery_id is minted HERE, once per finalize: ActiveJob retries of the
  # delivery repeat the argument (so consumers dedupe), while a later re-run of
  # the pipeline is a new delivery and gets its own id — even when it lands the
  # session back on the status it already reported.
  def enqueue_webhook(session)
    return if session.callback_url.blank?

    ScribeWebhookJob.perform_later(session.id, SecureRandom.uuid)
  rescue StandardError => e
    Rails.logger.error("ScribeWebhookJob enqueue failed for session=#{session.id}: #{e.class}: #{e.message}")
  end
end
