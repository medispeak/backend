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
# Delivery is at-least-once: transport errors AND non-2xx responses retry with
# backoff, so an endpoint that is down or mid-deploy still gets the
# notification. Consumers dedupe on delivery_id, which is stable across those
# retries.
class ScribeWebhookJob < ApplicationJob
  OPEN_TIMEOUT_SECONDS = 5
  READ_TIMEOUT_SECONDS = 10
  MAX_DELIVERY_ATTEMPTS = 5

  retry_on Faraday::Error, wait: :polynomially_longer, attempts: MAX_DELIVERY_ATTEMPTS do |job, error|
    Rails.logger.error(
      "ScribeWebhookJob gave up for session=#{job.arguments.first} after " \
      "#{MAX_DELIVERY_ATTEMPTS} attempts: #{error.class}: #{error.message}"
    )
  end

  # A blocked target is a refusal, not a transient fault — retrying just re-runs
  # the same rebind attempt.
  discard_on Scribe::WebhookTarget::UnsafeTarget do |job, error|
    Rails.logger.error("ScribeWebhookJob refused target for session=#{job.arguments.first}: #{error.message}")
  end

  # delivery_id is allocated by the enqueuer so that ActiveJob retries of THIS
  # delivery repeat it, while a later re-run of the pipeline (the retry API)
  # gets its own. Nil is a job enqueued before that argument existed.
  def perform(scribe_session_id, delivery_id = nil)
    session = ScribeSession.find_by(id: scribe_session_id)
    return if session.nil?
    return if session.callback_url.blank?

    payload = build_payload(session, delivery_id)
    json = payload.to_json
    timestamp = Time.now.to_i

    signature = Scribe::WebhookSigner.signature(
      secret: session.account.webhook_secret,
      timestamp: timestamp,
      payload: json
    )

    deliver(session.callback_url, json, signature)
  end

  private

  # Explicit allowlist — no transcript text, no field values.
  def build_payload(session, delivery_id)
    {
      session_id: session.id,
      status: session.status,
      outputs: session.scribe_outputs.map do |output|
        { id: output.id, output_type: output.output_type, status: output.status }
      end,
      delivery_id: delivery_id.presence || fallback_delivery_id(session),
      sent_at: Time.now.utc.iso8601
    }
  end

  # Legacy key for a job enqueued without a delivery_id: stable per
  # (session, status), which is all that was available then.
  def fallback_delivery_id(session)
    Digest::UUID.uuid_v5(
      Digest::UUID::OID_NAMESPACE,
      "scribe-session:#{session.id}:#{session.status}"
    )
  end

  def deliver(url, json, signature)
    uri = Scribe::WebhookTarget.https_uri(url)
    raise Scribe::WebhookTarget::UnsafeTarget, "#{url.inspect} is not a valid https URL" if uri.nil?

    address = Scribe::WebhookTarget.pin(uri)

    connection = Faraday.new do |f|
      # Without this a 4xx/5xx from the consumer looks exactly like a delivery.
      f.response :raise_error
      # Connect to the address just verified, keeping the hostname for SNI and
      # certificate verification: re-resolving here is what a rebind exploits.
      f.adapter :net_http do |http|
        http.ipaddr = address
      end
    end

    connection.post(uri) do |req|
      req.options.open_timeout = OPEN_TIMEOUT_SECONDS
      req.options.timeout = READ_TIMEOUT_SECONDS
      req.headers["Content-Type"] = "application/json"
      req.headers["X-Medispeak-Signature"] = signature
      req.body = json
    end
  end
end
