require "mocha/minitest"

# Webhook delivery resolves the callback host and connects to that verified
# address (Scribe::WebhookTarget), so a test that stubs the HTTP has to answer
# DNS too — the example hostnames used in tests do not resolve.
module WebhookDeliveryHelper
  # TEST-NET-3: reserved for documentation, never routable, and outside every
  # blocked range.
  PUBLIC_TEST_ADDRESS = "203.0.113.10".freeze

  def stub_webhook_dns(address = PUBLIC_TEST_ADDRESS)
    Resolv.stubs(:getaddresses).returns([ address ])
  end
end

ActiveSupport::TestCase.include(WebhookDeliveryHelper)
