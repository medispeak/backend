require "test_helper"

class RateLimitTest < ActionDispatch::IntegrationTest
  setup do
    Rails.cache.clear
  end

  teardown do
    Rails.cache.clear
  end

  test "throttles API requests per account once the configured rpm is exceeded" do
    skip "rack-attack not installed" unless defined?(Rack::Attack)

    account = create(:account, settings: { "rpm" => 2 })
    user = create(:user, account: account)
    api_token = create(:api_token, user: user, account: account)

    headers = { "Authorization" => "Bearer #{api_token.raw_token}" }

    # First two requests are within the per-minute budget.
    get "/api/v2/usage", headers: headers
    assert_response :success
    get "/api/v2/usage", headers: headers
    assert_response :success

    # Third request exceeds rpm=2 and must be throttled.
    get "/api/v2/usage", headers: headers
    assert_response :too_many_requests

    body = JSON.parse(response.body)
    assert_equal "rate_limited", body.dig("error", "code")
    assert_equal "Rate limit exceeded", body.dig("error", "message")

    assert response.headers["Retry-After"].present?
    assert_equal "2", response.headers["RateLimit-Limit"]
    assert_equal "0", response.headers["RateLimit-Remaining"]
    assert response.headers["RateLimit-Reset"].present?
  end

  test "throttles scoped SESSION tokens against the same per-account budget (no bypass)" do
    skip "rack-attack not installed" unless defined?(Rack::Attack)

    account = create(:account, settings: { "rpm" => 2 })
    user = create(:user, account: account)
    api_token = create(:api_token, user: user, account: account)
    session = create(:scribe_session, account: account, api_token: api_token, user: user)
    token, = Scribe::SessionToken.mint(session)
    headers = { "Authorization" => "Bearer #{token}" }
    url = "/api/v2/scribe_sessions/#{session.id}"

    # Session tokens are stateless (not ApiToken rows); without the discriminator
    # fallback they skipped throttling entirely. Now they count against the
    # account's rpm=2 like any other credential.
    get url, headers: headers
    assert_response :accepted
    get url, headers: headers
    assert_response :accepted
    get url, headers: headers
    assert_response :too_many_requests
    assert_equal "rate_limited", JSON.parse(response.body).dig("error", "code")
  end

  test "does not throttle unauthenticated or non-api requests" do
    skip "rack-attack not installed" unless defined?(Rack::Attack)

    # No bearer token: request resolves to no account and is not throttled by
    # rack-attack (it is still rejected by the controller as unauthorized).
    10.times do
      get "/api/v2/usage"
      assert_response :unauthorized
    end
  end

  test "throttles repeated sign-in attempts from one IP" do
    skip "rack-attack not installed" unless defined?(Rack::Attack)

    # Vary the email so only the per-IP throttle (limit 10) accumulates.
    10.times do |n|
      post "/users/sign_in", params: { user: { email: "person#{n}@example.com", password: "wrong" } }
    end

    post "/users/sign_in", params: { user: { email: "person-final@example.com", password: "wrong" } }
    assert_response :too_many_requests
    assert_equal "rate_limited", JSON.parse(response.body).dig("error", "code")
  end

  test "throttles repeated sign-in attempts against one email" do
    skip "rack-attack not installed" unless defined?(Rack::Attack)

    5.times do
      post "/users/sign_in", params: { user: { email: "victim@example.com", password: "wrong" } }
    end

    post "/users/sign_in", params: { user: { email: "victim@example.com", password: "wrong" } }
    assert_response :too_many_requests
  end
end
