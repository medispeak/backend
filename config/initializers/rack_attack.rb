# frozen_string_literal: true

# Account-keyed API rate limiting (design §6 point 6, §7 step 8).
#
# Throttling is keyed on the resolved `account_id` rather than the raw bearer
# token: an account that mints N tokens must not get N times the cap. Limit and
# period come from the account's own `settings` ("rpm", default 120 over 60s).
#
# The whole file is guarded by `defined?(Rack::Attack)` so the app still boots
# when the gem has not been installed/required yet. rack-attack auto-inserts its
# middleware via its Railtie when the gem is required, so no explicit
# `config.middleware.use` (and no application.rb change) is needed.
if defined?(Rack::Attack)
  class Rack::Attack
    # Default requests-per-minute when an account has not configured its own.
    DEFAULT_RPM = 120

    # Window, in seconds, that the RPM budget is measured over.
    RPM_PERIOD = 60

    # Back the throttle counters with the Rails cache (memory_store in test,
    # solid_cache in production). A real store is required for throttling to
    # actually take effect.
    self.cache.store = Rails.cache

    # Throttle authenticated API traffic per account. Returns a discriminator
    # (the account id) to count against, or nil to skip throttling entirely
    # (unauthenticated requests and non-/api/ paths fall through untouched).
    throttle("api/account/rpm", limit: proc { |req| req.env["rack.attack.account_rpm"] },
                                period: RPM_PERIOD) do |req|
      next nil unless req.path.start_with?("/api/")

      token = req.get_header("HTTP_AUTHORIZATION").to_s.split(" ").last
      account_id = ApiToken.authenticate(token)&.account_id
      next nil if account_id.nil?

      # Resolve this account's per-minute budget and stash it so the `limit`
      # proc above can read it (it receives the same request object).
      settings = Account.find_by(id: account_id)&.settings || {}
      req.env["rack.attack.account_rpm"] = (settings["rpm"] || DEFAULT_RPM).to_i

      account_id
    end

    # JSON 429 with standard rate-limit headers (epoch-second Reset/Retry-After).
    self.throttled_responder = lambda do |req|
      match_data = req.env["rack.attack.match_data"] || {}
      now = match_data[:epoch_time] || Time.now.to_i
      period = match_data[:period].to_i
      limit = match_data[:limit].to_i
      reset = period.positive? ? (now + (period - (now % period))) : now
      retry_after = [ reset - now, 0 ].max

      headers = {
        "Content-Type" => "application/json",
        "RateLimit-Limit" => limit.to_s,
        "RateLimit-Remaining" => "0",
        "RateLimit-Reset" => reset.to_s,
        "Retry-After" => retry_after.to_s
      }

      body = {
        error: {
          code: "rate_limited",
          message: "Rate limit exceeded"
        }
      }.to_json

      [ 429, headers, [ body ] ]
    end
  end
end
