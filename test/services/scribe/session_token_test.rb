require "test_helper"

class Scribe::SessionTokenTest < ActiveSupport::TestCase
  setup { @session = create(:scribe_session, expires_at: 1.hour.from_now) }

  test "mint then verify round-trips sid and scope" do
    token, exp = Scribe::SessionToken.mint(@session)
    assert token.start_with?("mss_")
    assert exp <= @session.expires_at
    claims = Scribe::SessionToken.verify(token)
    assert_equal @session.id, claims["sid"]
    assert_equal Scribe::SessionToken::SCOPE, claims["scope"]
    assert_includes claims["scope"], "document"
  end

  test "verify rejects tampered, foreign-prefix, and expired tokens" do
    token, = Scribe::SessionToken.mint(@session)
    assert_nil Scribe::SessionToken.verify(token + "x")
    assert_nil Scribe::SessionToken.verify("msk_live_whatever")
    expired, = Scribe::SessionToken.mint(@session, ttl: -1.second)
    assert_nil Scribe::SessionToken.verify(expired)
  end
end
