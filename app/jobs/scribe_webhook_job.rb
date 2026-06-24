# Delivers the completion webhook for a scribe session.
#
# The body is PHI-LIGHT by design (spec 7): an explicit allowlist of
# session_id, status, per-output {id, output_type, status}, a unique
# delivery_id, and a sent_at timestamp. It deliberately carries NO transcript
# text and NO structured field values — consumers fetch full results via the
# authenticated GET endpoint.
#
# The raw JSON body is signed with HMAC-SHA256 (Scribe::WebhookSigner) and sent
# in the X-Medispeak-Signature header so the consumer can verify authenticity.
#
# Delivery is at-least-once: Faraday transport errors are logged and swallowed
# so ActiveJob's retry machinery (or a manual replay) can re-deliver.
class ScribeWebhookJob < ApplicationJob
  def perform(scribe_session_id)
    session = ScribeSession.find_by(id: scribe_session_id)
    return if session.nil?
    return if session.callback_url.blank?

    payload = build_payload(session)
    json = payload.to_json
    timestamp = Time.now.to_i

    signature = Scribe::WebhookSigner.signature(
      secret: session.account.webhook_secret,
      timestamp: timestamp,
      payload: json
    )

    deliver(session.callback_url, json, signature)
  rescue Faraday::Error => e
    Rails.logger.warn("ScribeWebhookJob delivery failed for session=#{scribe_session_id}: #{e.class}: #{e.message}")
    nil
  end

  private

  # Explicit allowlist — no transcript text, no field values.
  def build_payload(session)
    {
      session_id: session.id,
      status: session.status,
      outputs: session.scribe_outputs.map do |output|
        { id: output.id, output_type: output.output_type, status: output.status }
      end,
      delivery_id: SecureRandom.uuid,
      sent_at: Time.now.utc.iso8601
    }
  end

  def deliver(url, json, signature)
    Faraday.post(url) do |req|
      req.headers["Content-Type"] = "application/json"
      req.headers["X-Medispeak-Signature"] = signature
      req.body = json
    end
  end
end
