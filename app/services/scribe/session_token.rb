module Scribe
  # Stateless, signed, short-lived token scoping a browser client to ONE scribe
  # session's upload+read routes. No DB row: verification is a signature check;
  # revocation rides on the short TTL and the session's own expiry/status.
  module SessionToken
    PREFIX = "mss_"
    # The routes a scoped token may reach. Nothing reads this claim yet — the
    # actual boundary is `sid`, enforced in ScribeSessionsController#find_session,
    # plus `require_account_token!` on the account-wide actions. It is listed
    # honestly all the same: a document session's client uploads to /documents,
    # and a scope that said "audio" while permitting documents would be a trap
    # for whoever implements enforcement.
    SCOPE = %w[audio document read].freeze
    DEFAULT_TTL = 15.minutes

    module_function

    def mint(session, ttl: DEFAULT_TTL)
      exp = [ ttl.from_now, session.expires_at ].compact.min
      token = PREFIX + verifier.generate({ "sid" => session.id, "scope" => SCOPE }, expires_at: exp)
      [ token, exp ]
    end

    def verify(raw)
      return nil unless raw.to_s.start_with?(PREFIX)

      verifier.verify(raw.delete_prefix(PREFIX))
    rescue ActiveSupport::MessageVerifier::InvalidSignature
      nil # covers tampering AND expiry (ExpiredMessage < InvalidSignature)
    end

    def verifier
      Rails.application.message_verifier(:scribe_session)
    end
  end
end
