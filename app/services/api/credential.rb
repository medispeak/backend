module Api
  # The caller behind one API request, resolved ONCE.
  #
  # Two layers need to know who is calling: Rack::Attack, to find the account
  # whose rate budget to spend, and the controller, to authorize and scope the
  # work. They used to resolve the same bearer string independently, so every
  # request — every poll, every segment upload — paid for the same lookups
  # twice. The first resolution is stashed in the Rack env, which both layers
  # share, so the second is free.
  #
  # Resolution is lazy: nothing is queried until something asks. A request that
  # never reaches the throttle (a non-/api path) resolves in the controller as
  # before, so this is an optimisation, never a dependency.
  class Credential
    ENV_KEY = "medispeak.api_credential".freeze

    # The credential for this request, memoized in the Rack env shared by the
    # middleware stack and the controller. Accepts any Rack/ActionDispatch
    # request.
    def self.for(request)
      env = request.env
      env[ENV_KEY] ||= new(bearer_token(request))
    end

    def self.bearer_token(request)
      request.get_header("HTTP_AUTHORIZATION").to_s.split(" ").last
    end

    def initialize(raw_token)
      @raw_token = raw_token.to_s
    end

    # The account API token, or nil. A scoped session token is a signed blob and
    # never an ApiToken row, so it skips the digest lookup entirely rather than
    # spending a query to miss.
    def api_token
      return @api_token if defined?(@api_token)

      @api_token = session_token? ? nil : ApiToken.authenticate(@raw_token)
    end

    # Claims of a scoped session (mss_) token, or nil. Signature + expiry check;
    # no DB row.
    def session_claims
      return @session_claims if defined?(@session_claims)

      @session_claims = Scribe::SessionToken.verify(@raw_token)
    end

    # The account an ACCOUNT token belongs to. Deliberately nil for a scoped
    # session token: that credential must never reach an account-wide surface,
    # and controllers gate on exactly this.
    def account
      return @account if defined?(@account)

      @account = api_token&.account
    end

    # The account whose rate-limit budget this request spends. Unlike #account
    # this DOES resolve a session token to its session's account, so browser
    # traffic counts against the same per-account budget as account tokens.
    def throttled_account_id
      return @throttled_account_id if defined?(@throttled_account_id)

      @throttled_account_id = api_token&.account_id || session_account_id
    end

    private

    def session_token?
      @raw_token.start_with?(Scribe::SessionToken::PREFIX)
    end

    def session_account_id
      claims = session_claims
      return nil unless claims

      ScribeSession.where(id: claims["sid"]).pick(:account_id)
    end
  end
end
