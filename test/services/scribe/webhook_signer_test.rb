require "test_helper"

class ScribeWebhookSignerTest < ActiveSupport::TestCase
  test "produces a deterministic t=...,v1=... signature" do
    secret = "whsec_test_secret"
    timestamp = 1_700_000_000
    payload = { session_id: 1, status: "completed" }.to_json

    sig1 = Scribe::WebhookSigner.signature(secret: secret, timestamp: timestamp, payload: payload)
    sig2 = Scribe::WebhookSigner.signature(secret: secret, timestamp: timestamp, payload: payload)

    assert_equal sig1, sig2, "same inputs must yield the same signature"
    assert_match(/\At=#{timestamp},v1=[0-9a-f]{64}\z/, sig1)
  end

  test "signs the raw body composed as timestamp + '.' + payload" do
    secret = "whsec_test_secret"
    timestamp = 1_700_000_000
    payload = %({"session_id":1,"status":"completed"})

    expected_digest = OpenSSL::HMAC.hexdigest("SHA256", secret, "#{timestamp}.#{payload}")

    sig = Scribe::WebhookSigner.signature(secret: secret, timestamp: timestamp, payload: payload)

    assert_equal "t=#{timestamp},v1=#{expected_digest}", sig
  end

  test "changing the payload changes the signature" do
    secret = "whsec_test_secret"
    timestamp = 1_700_000_000

    sig_a = Scribe::WebhookSigner.signature(secret: secret, timestamp: timestamp, payload: %({"a":1}))
    sig_b = Scribe::WebhookSigner.signature(secret: secret, timestamp: timestamp, payload: %({"a":2}))

    refute_equal sig_a, sig_b
  end

  test "changing the timestamp changes the signature" do
    secret = "whsec_test_secret"
    payload = %({"a":1})

    sig_a = Scribe::WebhookSigner.signature(secret: secret, timestamp: 1_700_000_000, payload: payload)
    sig_b = Scribe::WebhookSigner.signature(secret: secret, timestamp: 1_700_000_001, payload: payload)

    refute_equal sig_a, sig_b
  end
end
