module Scribe
  # Computes the value for the `X-Medispeak-Signature` webhook header.
  #
  # Format (design spec 7): `t=<unix>,v1=<hex>` where
  #   v1 = HMAC-SHA256(secret, "<t>.<raw_body>")
  #
  # The signature is over the RAW JSON body (the exact bytes sent on the wire),
  # not a re-serialized hash, so consumers can verify without re-encoding. Both
  # the signer and the verifier must use the same string: timestamp + "." + payload.
  class WebhookSigner
    def self.signature(secret:, timestamp:, payload:)
      signed_payload = "#{timestamp}.#{payload}"
      digest = OpenSSL::HMAC.hexdigest("SHA256", secret.to_s, signed_payload)
      "t=#{timestamp},v1=#{digest}"
    end
  end
end
