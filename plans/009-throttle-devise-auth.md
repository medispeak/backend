# Plan 009: Throttle Devise login and password-reset endpoints

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan
> in `plans/README.md` — unless a reviewer dispatched you and told you they
> maintain the index.
>
> **Drift check (run first)**:
> `git diff --stat 84da325..HEAD -- config/initializers/rack_attack.rb config/routes.rb test/integration/rate_limit_test.rb`
> If any in-scope file changed since this plan was written, compare the
> "Current state" excerpts against the live code before proceeding; on a
> mismatch, treat it as a STOP condition.

## Status

- **Priority**: P2
- **Effort**: S
- **Risk**: LOW
- **Depends on**: none
- **Category**: security
- **Planned at**: commit `84da325`, 2026-07-08

## Why this matters

Finding F9: rack-attack throttling is scoped to `/api/` paths only, so the
browser-facing Devise endpoints — `POST /users/sign_in` (login) and
`POST /users/password` (password reset) — are completely unthrottled. That
leaves them open to credential-stuffing and password brute-force, and lets
password-reset be abused to blast reset emails at arbitrary addresses. This plan
adds rack-attack throttles for those two endpoints, keyed both on client IP and
on the submitted email, while leaving the existing account-keyed API throttle
untouched.

## Current state

- `config/initializers/rack_attack.rb:26-43` — the ONLY throttle today bails out
  for non-`/api/` paths, which is exactly why Devise routes are unprotected:
  ```ruby
  throttle("api/account/rpm", limit: proc { |req| req.env["rack.attack.account_rpm"] },
                              period: RPM_PERIOD) do |req|
    next nil unless req.path.start_with?("/api/")

    token = req.get_header("HTTP_AUTHORIZATION").to_s.split(" ").last
    account_id = ApiToken.authenticate(token)&.account_id
    next nil if account_id.nil?

    settings = Account.find_by(id: account_id)&.settings || {}
    req.env["rack.attack.account_rpm"] = (settings["rpm"] || DEFAULT_RPM).to_i

    account_id
  end
  ```
  The whole file is wrapped in `if defined?(Rack::Attack)` (`:13`), and a shared
  `throttled_responder` (`:46-70`) already returns a JSON `429` with
  `RateLimit-*` / `Retry-After` headers for every throttle.

- `config/routes.rb:18` — `devise_for :users` mounts the standard Devise routes,
  including `POST /users/sign_in` (session create) and `POST /users/password`
  (password create/reset). Devise submits the email as `user[email]`.

- Test facts: `test/integration/rate_limit_test.rb` is the pattern. It guards
  every test with `skip "rack-attack not installed" unless defined?(Rack::Attack)`
  and clears `Rails.cache` in `setup`/`teardown`. `config.action_controller.allow_forgery_protection = false`
  in `config/environments/test.rb`, so `POST /users/sign_in` works in tests
  without a CSRF token.

## Commands you will need

| Purpose      | Command                                                                | Expected on success |
|--------------|------------------------------------------------------------------------|---------------------|
| Rate test    | `ASDF_RUBY_VERSION=3.2.2 bin/rails test test/integration/rate_limit_test.rb` | all pass       |
| Full tests   | `ASDF_RUBY_VERSION=3.2.2 bin/rails test`                                | 0 failures          |
| Lint         | `ASDF_RUBY_VERSION=3.2.2 bin/rubocop`                                   | no offenses         |

## Scope

**In scope** (the only files you should modify):
- `config/initializers/rack_attack.rb`
- `test/integration/rate_limit_test.rb`

**Out of scope** (do NOT touch, even though they look related):
- The existing `api/account/rpm` throttle and the `throttled_responder` — leave
  both exactly as-is; the new throttles reuse the same responder.
- `config/routes.rb` — the Devise routes already exist; do NOT add or change
  routes.
- Enabling Devise `:lockable` — noted as an option in Maintenance notes; it needs
  a migration + model change and is NOT part of this plan.

## Git workflow

- Branch: `advisor/009-throttle-devise-auth`
- One commit; short imperative subject (e.g.
  `Throttle Devise sign-in and password-reset`).
- Do NOT push or open a PR unless the operator instructed it.

## Steps

### Step 1: Add IP + email throttles for the Devise endpoints

In `config/initializers/rack_attack.rb`, inside the `class Rack::Attack` body
(after the existing `throttle("api/account/rpm", …)` block, still within the
`if defined?(Rack::Attack)` guard), add two throttles. Target shape:
```ruby
# Devise auth endpoints are browser-facing (not under /api/) and were
# previously unthrottled. Guard login + password-reset against brute force /
# credential stuffing / reset-email abuse, keyed on IP and on submitted email.
DEVISE_AUTH_PATHS = ["/users/sign_in", "/users/password"].freeze

def self.devise_auth_request?(req)
  req.post? && DEVISE_AUTH_PATHS.include?(req.path)
end

# Per-IP: caps total auth attempts from one source address.
throttle("devise/auth/ip", limit: 10, period: 60) do |req|
  req.ip if devise_auth_request?(req)
end

# Per-email: caps attempts against a single account, independent of IP.
throttle("devise/auth/email", limit: 5, period: 60) do |req|
  if devise_auth_request?(req)
    req.params.dig("user", "email").presence&.downcase&.strip
  end
end
```
Notes: `req` is a `Rack::Attack::Request` (a `Rack::Request`), so `req.ip`,
`req.post?`, `req.path`, and `req.params` are all available; a throttle block
that returns `nil` skips throttling for that request. Do NOT wrap the whole file
in a second `if defined?` — you are adding inside the existing one.

**Verify**: `grep -n "devise/auth" config/initializers/rack_attack.rb`
→ two throttle names present.

### Step 2: Add rate-limit tests for both endpoints

In `test/integration/rate_limit_test.rb`, add two tests. Keep the existing
`skip … unless defined?(Rack::Attack)` guard and the `Rails.cache` clearing in
`setup`/`teardown` (already in the file). Model them on the existing
"throttles API requests per account…" test.

The IP throttle (limit 10) is isolated by varying the email each request so the
email throttle (limit 5) never accumulates for a single address:
```ruby
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
```
The email throttle (limit 5) is isolated by reusing one email — it trips at the
6th request (IP count is only 6, below the IP limit of 10):
```ruby
test "throttles repeated sign-in attempts against one email" do
  skip "rack-attack not installed" unless defined?(Rack::Attack)

  5.times do
    post "/users/sign_in", params: { user: { email: "victim@example.com", password: "wrong" } }
  end

  post "/users/sign_in", params: { user: { email: "victim@example.com", password: "wrong" } }
  assert_response :too_many_requests
end
```

**Verify**:
`ASDF_RUBY_VERSION=3.2.2 bin/rails test test/integration/rate_limit_test.rb`
→ all tests pass (existing 2 + new 2). Confirm the existing API-throttle tests
still pass (the new throttles only match `/users/...`).

## Test plan

- New tests in `test/integration/rate_limit_test.rb`:
  - "throttles repeated sign-in attempts from one IP" — 11th attempt (varied
    emails) → `429` with `error.code == "rate_limited"`. This is the F9
    regression for the IP key.
  - "throttles repeated sign-in attempts against one email" — 6th attempt (same
    email) → `429`. Regression for the email key.
- Structural pattern: the existing "throttles API requests per account once the
  configured rpm is exceeded" test in the same file (loop, then assert
  `:too_many_requests` and the JSON error envelope).
- Verification: `ASDF_RUBY_VERSION=3.2.2 bin/rails test` → 0 failures.

## Done criteria

Machine-checkable. ALL must hold:

- [ ] `grep -n "devise/auth/ip\|devise/auth/email" config/initializers/rack_attack.rb` returns both throttle names
- [ ] The existing `api/account/rpm` throttle block is unchanged (`git diff` shows only additions in this file)
- [ ] `ASDF_RUBY_VERSION=3.2.2 bin/rails test test/integration/rate_limit_test.rb` passes, including the 2 new tests
- [ ] `ASDF_RUBY_VERSION=3.2.2 bin/rails test` exits 0 with 0 failures
- [ ] `ASDF_RUBY_VERSION=3.2.2 bin/rubocop` reports no offenses
- [ ] No files outside the in-scope list are modified (`git status`)
- [ ] `plans/README.md` status row updated

## STOP conditions

Stop and report back (do not improvise) if:

- `config/initializers/rack_attack.rb` or the Devise routes no longer match the
  "Current state" excerpts (drift) — e.g. `devise_for` uses a custom path scope,
  so `/users/sign_in` is wrong. Confirm the real paths with
  `ASDF_RUBY_VERSION=3.2.2 bin/rails routes -g devise` before proceeding.
- A new throttle test never returns `429` even after exceeding the limit — likely
  `Rails.cache` is a null store in test or the throttle key returned `nil`;
  report rather than raising the limits to force a pass.
- Adding the throttles breaks the existing "does not throttle unauthenticated or
  non-api requests" test (that would mean a new throttle is matching `/api/`
  paths — it must not).

## Maintenance notes

For the human/agent who owns this after the change lands:

- The limits (IP 10/60s, email 5/60s) are conservative starting points. Shared
  NAT / office IPs may legitimately exceed the IP cap; tune with real traffic and
  consider a `safelist` for known office egress IPs if false positives appear.
- The shared `throttled_responder` returns a JSON `429`. For the HTML Devise
  forms that is functionally correct (still a `429`) but not a pretty page; a
  follow-up could branch the responder on `req.path` to render an HTML
  rate-limit page for browser routes.
- **Option (deferred)**: enable Devise `:lockable` for account lockout after N
  failed attempts. That requires adding lockable columns via migration and the
  module to the `User` model — a larger change than this edge throttle, tracked
  separately.
- A reviewer should confirm the two new throttles NEVER match `/api/` paths (so
  they don't double-count against the account RPM throttle).
