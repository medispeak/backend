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

    if session.callback_url.present?
      ScribeWebhookJob.perform_later(session.id)
    end
  rescue StandardError => e
    session&.update(status: :failed, error: { message: e.message })
    Rails.logger.error("ProcessScribeSessionJob failed for session=#{scribe_session_id}: #{e.class}: #{e.message}")
    nil
  end
end
