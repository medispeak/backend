require "test_helper"
require "mocha/minitest"
require "ostruct"

class ScribeWebhookJobTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  def build_session(callback_url:)
    account = create(:account)
    session = create(:scribe_session, account: account, status: "completed",
                                      callback_url: callback_url)
    create(:scribe_output, scribe_session: session, output_type: "transcript", status: "success")
    create(:scribe_output, scribe_session: session, output_type: "form", status: "success")
    session
  end

  test "POSTs a signed JSON body to the callback url" do
    stub_webhook_dns
    callback_url = "https://client.example.com/webhook"
    captured = nil
    stub_request(:post, callback_url).to_return do |req|
      captured = req
      { status: 200, body: "" }
    end

    session = build_session(callback_url: callback_url)

    ScribeWebhookJob.perform_now(session.id)

    assert_requested :post, callback_url, times: 1
    assert_not_nil captured

    # Signature header is present and matches the t=...,v1=... format.
    header = captured.headers["X-Medispeak-Signature"]
    assert_match(/\At=\d+,v1=[0-9a-f]{64}\z/, header)
    assert_includes captured.headers["Content-Type"].to_s, "application/json"

    # Signature actually verifies against the raw body + the account secret.
    t = header[/t=(\d+),/, 1]
    v1 = header[/v1=([0-9a-f]{64})/, 1]
    expected = OpenSSL::HMAC.hexdigest("SHA256", session.account.webhook_secret, "#{t}.#{captured.body}")
    assert_equal expected, v1
  end

  test "body carries only the PHI-light allowlist" do
    stub_webhook_dns
    callback_url = "https://client.example.com/webhook"
    captured_body = nil
    stub_request(:post, callback_url).to_return do |req|
      captured_body = req.body
      { status: 200, body: "" }
    end

    session = build_session(callback_url: callback_url)

    ScribeWebhookJob.perform_now(session.id)

    parsed = JSON.parse(captured_body)
    assert_equal %w[delivery_id outputs sent_at session_id status], parsed.keys.sort
    assert_equal session.id, parsed["session_id"]
    assert_equal "completed", parsed["status"]
    parsed["outputs"].each do |o|
      assert_equal %w[id output_type status], o.keys.sort
    end
  end

  test "delivery_id is stable across retries of the same delivery" do
    stub_webhook_dns
    callback_url = "https://client.example.com/webhook"
    bodies = []
    stub_request(:post, callback_url).to_return do |req|
      bodies << req.body
      { status: 200, body: "" }
    end

    session = build_session(callback_url: callback_url)
    delivery_id = SecureRandom.uuid

    ScribeWebhookJob.perform_now(session.id, delivery_id)
    ScribeWebhookJob.perform_now(session.id, delivery_id)

    assert_equal delivery_id, JSON.parse(bodies[0])["delivery_id"]
    assert_equal delivery_id, JSON.parse(bodies[1])["delivery_id"]
  end

  # A retried run can finish on the status it already reported (partial ->
  # processing -> partial) with different per-output detail. Keying the id on
  # (session, status) made that second, materially different payload look like a
  # duplicate to any consumer following the documented dedupe rule.
  test "a separate delivery of the same status gets its own delivery_id" do
    stub_webhook_dns
    callback_url = "https://client.example.com/webhook"
    bodies = []
    stub_request(:post, callback_url).to_return do |req|
      bodies << req.body
      { status: 200, body: "" }
    end

    session = build_session(callback_url: callback_url)

    ScribeWebhookJob.perform_now(session.id, SecureRandom.uuid)
    ScribeWebhookJob.perform_now(session.id, SecureRandom.uuid)

    assert_not_equal JSON.parse(bodies[0])["delivery_id"], JSON.parse(bodies[1])["delivery_id"]
  end

  test "falls back to a stable id when enqueued without one" do
    stub_webhook_dns
    callback_url = "https://client.example.com/webhook"
    bodies = []
    stub_request(:post, callback_url).to_return do |req|
      bodies << req.body
      { status: 200, body: "" }
    end

    session = build_session(callback_url: callback_url)

    ScribeWebhookJob.perform_now(session.id)
    ScribeWebhookJob.perform_now(session.id)

    first = JSON.parse(bodies[0])["delivery_id"]
    assert_equal first, JSON.parse(bodies[1])["delivery_id"]
    assert_match(/\A[0-9a-f-]{36}\z/, first)
  end

  test "is a no-op when the session is missing" do
    assert_nothing_raised { ScribeWebhookJob.perform_now(-1) }
  end

  test "is a no-op when callback_url is blank" do
    session = create(:scribe_session, callback_url: nil)
    assert_nothing_raised { ScribeWebhookJob.perform_now(session.id) }
    # No external HTTP attempted; webmock would raise on an unstubbed request.
  end

  test "retries delivery when the endpoint returns a non-2xx response" do
    stub_webhook_dns
    callback_url = "https://client.example.com/webhook"
    stub_request(:post, callback_url).to_return(status: 500, body: "boom")

    session = build_session(callback_url: callback_url)

    old_adapter = ActiveJob::Base.queue_adapter
    ActiveJob::Base.queue_adapter = :test

    ScribeWebhookJob.perform_now(session.id, SecureRandom.uuid)

    assert_equal 1, enqueued_jobs.count,
                 "a 5xx from the consumer must be retried, not counted as delivered"
  ensure
    ActiveJob::Base.queue_adapter = old_adapter
  end

  test "retries delivery on a transport error" do
    stub_webhook_dns
    callback_url = "https://client.example.com/webhook"
    stub_request(:post, callback_url).to_timeout

    session = build_session(callback_url: callback_url)

    old_adapter = ActiveJob::Base.queue_adapter
    ActiveJob::Base.queue_adapter = :test

    ScribeWebhookJob.perform_now(session.id, SecureRandom.uuid)

    assert_equal 1, enqueued_jobs.count
  ensure
    ActiveJob::Base.queue_adapter = old_adapter
  end

  # The URL passed validation when the session was created; by delivery time the
  # host answers with an internal address. Re-resolving at connect time is what
  # a rebind exploits, so the job refuses rather than delivering.
  test "refuses to deliver when the host now resolves to an internal address" do
    callback_url = "https://client.example.com/webhook"

    # Safe when the session is created — this is the half a create-time check
    # sees...
    stub_webhook_dns
    session = build_session(callback_url: callback_url)

    # ...and pointed at the cloud metadata endpoint by the time the job runs.
    stub_webhook_dns("169.254.169.254")

    assert_nothing_raised { ScribeWebhookJob.perform_now(session.id, SecureRandom.uuid) }
    assert_not_requested :post, callback_url
  end

  test "refuses to deliver when the host stops resolving" do
    stub_webhook_dns
    session = build_session(callback_url: "https://client.example.com/webhook")

    Resolv.stubs(:getaddresses).returns([])

    assert_nothing_raised { ScribeWebhookJob.perform_now(session.id, SecureRandom.uuid) }
    assert_not_requested :post, "https://client.example.com/webhook"
  end

  test "pins the connection to the verified address" do
    stub_webhook_dns("203.0.113.55")
    callback_url = "https://client.example.com/webhook"
    stub_request(:post, callback_url).to_return(status: 200, body: "")

    pinned = nil
    Net::HTTP.any_instance.stubs(:ipaddr=).with { |value| pinned = value }.returns(nil)

    session = build_session(callback_url: callback_url)
    ScribeWebhookJob.perform_now(session.id, SecureRandom.uuid)

    assert_equal "203.0.113.55", pinned
  end

  test "configures explicit open and read timeouts on the webhook request" do
    stub_webhook_dns
    captured = OpenStruct.new(headers: {}, options: OpenStruct.new)
    Faraday::Connection.any_instance.stubs(:post).yields(captured).returns(true)

    session = build_session(callback_url: "https://client.example.com/webhook")
    ScribeWebhookJob.perform_now(session.id, SecureRandom.uuid)

    assert_equal ScribeWebhookJob::OPEN_TIMEOUT_SECONDS, captured.options.open_timeout
    assert_equal ScribeWebhookJob::READ_TIMEOUT_SECONDS, captured.options.timeout
  end
end
