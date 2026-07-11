# Runs the scribe pipeline for one session asynchronously (solid_queue in
# prod; the :inline adapter in test runs it synchronously).
#
# Flow:
#   1. Load the session (no-op if it was deleted/expired).
#   2. Move it to :processing.
#   3. Run Scribe::Orchestrator (which sets the final completed/partial/failed
#      status and fills the outputs + transcript).
#   4. If the session has a callback_url, enqueue ScribeWebhookJob to deliver the
#      PHI-light completion notification.
#
# Any unexpected error marks the session :failed with a sanitized message and is
# logged but NOT re-raised, so a poison job does not retry forever. Metering is
# best-effort (see Scribe::Orchestrator#meter); a usage_event left :pending is
# swept to :failed by Metering::ReservationSweeper rather than trued up against
# the ledger (holds are postpaid and reserve no credit balance).
class ProcessScribeSessionJob < ApplicationJob
  def perform(scribe_session_id)
    session = ScribeSession.find_by(id: scribe_session_id)
    return if session.nil?

    session.update!(status: :processing)

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

  def enqueue_webhook(session)
    ScribeWebhookJob.perform_later(session.id) if session.callback_url.present?
  rescue StandardError => e
    Rails.logger.error("ScribeWebhookJob enqueue failed for session=#{session.id}: #{e.class}: #{e.message}")
  end
end
