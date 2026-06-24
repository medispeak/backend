require "test_helper"

class ScribeWebhookJobTest < ActiveSupport::TestCase
  def build_session(callback_url:)
    account = create(:account)
    session = create(:scribe_session, account: account, status: "completed",
                                      callback_url: callback_url)
    create(:scribe_output, scribe_session: session, output_type: "transcript", status: "success")
    create(:scribe_output, scribe_session: session, output_type: "form", status: "success")
    session
  end

  test "POSTs a signed JSON body to the callback url" do
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

  test "is a no-op when the session is missing" do
    assert_nothing_raised { ScribeWebhookJob.perform_now(-1) }
  end

  test "is a no-op when callback_url is blank" do
    session = create(:scribe_session, callback_url: nil)
    assert_nothing_raised { ScribeWebhookJob.perform_now(session.id) }
    # No external HTTP attempted; webmock would raise on an unstubbed request.
  end

  test "swallows Faraday transport errors so delivery can be retried" do
    callback_url = "https://client.example.com/webhook"
    stub_request(:post, callback_url).to_timeout

    session = build_session(callback_url: callback_url)

    assert_nothing_raised { ScribeWebhookJob.perform_now(session.id) }
  end
end
