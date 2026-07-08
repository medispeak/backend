# Plan 006: Validate webhook `callback_url` against SSRF and set explicit HTTP timeouts

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan
> in `plans/README.md` — unless a reviewer dispatched you and told you they
> maintain the index.
>
> **Drift check (run first)**:
> `git diff --stat 84da325..HEAD -- app/models/scribe_session.rb app/controllers/api/v2/scribe_sessions_controller.rb app/jobs/scribe_webhook_job.rb test/models/scribe_session_test.rb test/jobs/scribe_webhook_job_test.rb`
> If any in-scope file changed since this plan was written, compare the
> "Current state" excerpts against the live code before proceeding; on a
> mismatch, treat it as a STOP condition.

## Status

- **Priority**: P1
- **Effort**: S-M
- **Risk**: LOW
- **Depends on**: none
- **Category**: security
- **Planned at**: commit `84da325`, 2026-07-08

## Why this matters

Finding F5: the v2 Scribe API accepts a client-supplied `callback_url`, stores
it unvalidated, and later POSTs to it from a background job with `Faraday.post`
that has NO host allowlist and NO timeout. That is a classic SSRF sink: a caller
can point `callback_url` at `http://169.254.169.254/…` (cloud metadata),
`http://127.0.0.1:…`, or an internal RFC-1918 address and make the server issue
requests to infrastructure it can reach but the caller cannot. The missing
timeout also lets a hostile or slow endpoint tie up a worker indefinitely. This
plan validates the URL at the model boundary (require `https`; reject loopback,
link-local/metadata, and private ranges) so bad values are rejected with a
`validation_error` at create time, and sets explicit open/read timeouts on the
webhook request.

## Current state

- `app/controllers/api/v2/scribe_sessions_controller.rb:97-109` (`build_session`
  copies `callback_url` straight from params into the record):
  ```ruby
  def build_session
    ScribeSession.new(
      account: current_account,
      api_token: current_api_token,
      user: current_api_token.user,
      status: "created",
      language: create_params[:language_hint],
      mode: create_params[:mode].presence || "consultation",
      callback_url: create_params[:callback_url],
      idempotency_key: idempotency_key_header,
      expires_at: 24.hours.from_now
    )
  end
  ```

- `app/controllers/api/v2/scribe_sessions_controller.rb:169-174` (`callback_url`
  is permitted):
  ```ruby
  def create_params
    params.permit(
      :language_hint, :mode, :callback_url,
      outputs: [ :type, :page_id, :template_ref, { context: {} } ]
    )
  end
  ```

- The `create` action (`:9-27`) wraps everything in `with_idempotency` and
  already uses the "compute an error, `render_error`, `next`" pattern for outputs
  — the callback_url guard MUST follow the SAME shape (render + `next`), because a
  raw `save!` on an invalid record would raise and be caught by the global
  `rescue_from Exception` (`app/controllers/api/v2/base_controller.rb`), which
  returns a generic **500**, not the desired 422:
  ```ruby
  session = build_session
  session.save!
  build_outputs(session, outputs)

  render json: serialize(session), status: :created
  ```
  The v2 error envelope helper is `render_error(code:, message:, status:)`
  (defined in `app/controllers/api/v2/base_controller.rb`).

- `app/models/scribe_session.rb:1-30` — the model has NO URL validation today:
  ```ruby
  class ScribeSession < ApplicationRecord
    belongs_to :account
    belongs_to :api_token, optional: true
    belongs_to :user, optional: true
    ...
    validates :status, presence: true

    def expired?
      expires_at.present? && expires_at < Time.current
    end
  end
  ```

- `app/jobs/scribe_webhook_job.rb:51-57` (`deliver` — no timeout, no allowlist):
  ```ruby
  def deliver(url, json, signature)
    Faraday.post(url) do |req|
      req.headers["Content-Type"] = "application/json"
      req.headers["X-Medispeak-Signature"] = signature
      req.body = json
    end
  end
  ```
  The job already returns early when `callback_url` is blank
  (`app/jobs/scribe_webhook_job.rb:18`), so blank is a valid state and must stay
  valid on the model.

- Test facts: `faraday (2.12.2)` is in `Gemfile.lock`; the request block exposes
  `req.options` (a `Faraday::RequestOptions`) with `open_timeout=` / `timeout=`.
  Test stack is Minitest + webmock + mocha + factory_bot. The existing job tests
  and `test/jobs/process_scribe_session_job_test.rb` already use the callback
  host `https://client.example.com/...`, which does not resolve (NXDOMAIN) — so
  the new validation must treat an unresolvable host as allowed (it can reach
  nothing internal) to avoid breaking them.

## Commands you will need

| Purpose         | Command                                                                       | Expected on success |
|-----------------|-------------------------------------------------------------------------------|---------------------|
| Model test      | `ASDF_RUBY_VERSION=3.2.2 bin/rails test test/models/scribe_session_test.rb`    | all pass            |
| Job test        | `ASDF_RUBY_VERSION=3.2.2 bin/rails test test/jobs/scribe_webhook_job_test.rb`  | all pass            |
| v2 API test     | `ASDF_RUBY_VERSION=3.2.2 bin/rails test test/integration/api/v2/scribe_sessions_test.rb` | all pass |
| Full tests      | `ASDF_RUBY_VERSION=3.2.2 bin/rails test`                                       | 0 failures          |
| Lint            | `ASDF_RUBY_VERSION=3.2.2 bin/rubocop`                                          | no offenses         |
| Security scan   | `ASDF_RUBY_VERSION=3.2.2 bin/brakeman --no-pager`                             | no new warnings     |

## Scope

**In scope** (the only files you should modify):
- `app/models/scribe_session.rb`
- `app/controllers/api/v2/scribe_sessions_controller.rb`
- `app/jobs/scribe_webhook_job.rb`
- `test/models/scribe_session_test.rb`
- `test/jobs/scribe_webhook_job_test.rb`

**Out of scope** (do NOT touch, even though they look related):
- `app/controllers/api/v2/base_controller.rb` — do NOT add a global
  `rescue_from ActiveRecord::RecordInvalid`; the controller pre-validation in
  Step 2 keeps the 422 local and idempotency-correct.
- `app/jobs/process_scribe_session_job.rb` — it only enqueues `ScribeWebhookJob`;
  no change needed.
- `app/services/scribe/webhook_signer.rb` — signing is unrelated to SSRF.
- A per-account host allowlist — noted as a follow-up, not built here.

## Git workflow

- Branch: `advisor/006-validate-callback-url-ssrf`
- Commit per logical unit (model validation, controller guard, job timeout),
  short imperative subjects (e.g. `Reject SSRF-prone scribe callback_url`).
- Do NOT push or open a PR unless the operator instructed it.

## Steps

### Step 1: Add SSRF validation to `ScribeSession#callback_url`

In `app/models/scribe_session.rb`, add `require "resolv"` and `require "ipaddr"`
at the top, a blocked-range constant, a `validate` hook, and private helpers.
Target shape:
```ruby
require "resolv"
require "ipaddr"

class ScribeSession < ApplicationRecord
  # ... existing associations / enums / validations ...

  # Ranges a webhook must never target: loopback, RFC-1918 private, link-local
  # (incl. 169.254.169.254 cloud metadata), unspecified, and IPv6 equivalents.
  BLOCKED_IP_RANGES = [
    IPAddr.new("127.0.0.0/8"),
    IPAddr.new("10.0.0.0/8"),
    IPAddr.new("172.16.0.0/12"),
    IPAddr.new("192.168.0.0/16"),
    IPAddr.new("169.254.0.0/16"),
    IPAddr.new("0.0.0.0/8"),
    IPAddr.new("::1"),
    IPAddr.new("fc00::/7"),
    IPAddr.new("fe80::/10")
  ].freeze

  validates :status, presence: true
  validate :callback_url_is_safe

  def expired?
    expires_at.present? && expires_at < Time.current
  end

  private

  def callback_url_is_safe
    return if callback_url.blank?

    uri = parse_https_uri(callback_url)
    unless uri
      errors.add(:callback_url, "must be a valid https URL")
      return
    end

    if unsafe_host?(uri.hostname)
      errors.add(:callback_url, "must not point to a private, loopback, or link-local address")
    end
  end

  def parse_https_uri(value)
    uri = URI.parse(value)
    return nil unless uri.is_a?(URI::HTTPS) && uri.hostname.present?

    uri
  rescue URI::InvalidURIError
    nil
  end

  # A literal IP is checked directly; a hostname is resolved via DNS. An
  # unresolvable host resolves to [] and is treated as safe (it can reach
  # nothing internal).
  def unsafe_host?(host)
    ip_candidates(host).any? { |ip| blocked_ip?(ip) }
  end

  def ip_candidates(host)
    IPAddr.new(host) # raises unless host is already a literal IP
    [host]
  rescue IPAddr::InvalidAddressError
    resolve_addresses(host)
  end

  def resolve_addresses(host)
    Resolv.getaddresses(host)
  rescue StandardError
    []
  end

  def blocked_ip?(address)
    ip = IPAddr.new(address)
    BLOCKED_IP_RANGES.any? { |range| range.include?(ip) }
  rescue IPAddr::InvalidAddressError
    false
  end
end
```
Notes for the executor: keep the existing `validates :status, presence: true`
line; `uri.hostname` (not `uri.host`) is used so bracketed IPv6 hosts are
normalized. Do not remove the existing `expired?` method.

**Verify**: `ASDF_RUBY_VERSION=3.2.2 bin/rails runner 'puts ScribeSession.new(account_id: 1, status: %q(created), callback_url: %q(http://127.0.0.1)).tap(&:valid?).errors[:callback_url].inspect'`
→ prints a non-empty array (the http/loopback URL is rejected). (Any missing-DB
error means run the model test in Step 4 instead.)

### Step 2: Reject invalid `callback_url` with a 422 in the controller

In `app/controllers/api/v2/scribe_sessions_controller.rb`, inside `create`, after
`session = build_session` and BEFORE `session.save!`, add a pre-flight validation
that surfaces the model error as the v2 `validation_error` envelope. Use `next`
(the action body runs inside the `with_idempotency` block):
```ruby
session = build_session
unless session.valid?
  render_error(
    code: "validation_error",
    message: session.errors.full_messages.to_sentence,
    status: :unprocessable_entity
  )
  next
end
session.save!
build_outputs(session, outputs)

render json: serialize(session), status: :created
```

**Verify**: `grep -n "session.valid?" app/controllers/api/v2/scribe_sessions_controller.rb`
→ one match, placed before `session.save!`.

### Step 3: Set explicit open/read timeouts on the webhook request

In `app/jobs/scribe_webhook_job.rb`, add timeout constants at the top of the
class and apply them in `deliver`:
```ruby
class ScribeWebhookJob < ApplicationJob
  OPEN_TIMEOUT_SECONDS = 5
  READ_TIMEOUT_SECONDS = 10

  # ... perform / build_payload unchanged ...

  def deliver(url, json, signature)
    Faraday.post(url) do |req|
      req.options.open_timeout = OPEN_TIMEOUT_SECONDS
      req.options.timeout = READ_TIMEOUT_SECONDS
      req.headers["Content-Type"] = "application/json"
      req.headers["X-Medispeak-Signature"] = signature
      req.body = json
    end
  end
end
```

**Verify**: `grep -n "open_timeout\|timeout =" app/jobs/scribe_webhook_job.rb`
→ shows both timeout assignments.

### Step 4: Add model + job tests

In `test/models/scribe_session_test.rb`, add (model after the existing
`build(:scribe_session, ...)` assertion style in that file):
```ruby
test "rejects a non-https callback_url" do
  session = build(:scribe_session, callback_url: "http://example.com/webhook")
  refute session.valid?
  assert_match(/https/, session.errors[:callback_url].join)
end

test "rejects a loopback callback_url" do
  session = build(:scribe_session, callback_url: "https://127.0.0.1/webhook")
  refute session.valid?
end

test "rejects the cloud-metadata callback_url" do
  session = build(:scribe_session, callback_url: "https://169.254.169.254/latest/meta-data")
  refute session.valid?
end

test "rejects a private RFC-1918 callback_url" do
  session = build(:scribe_session, callback_url: "https://10.0.0.5/webhook")
  refute session.valid?
end

test "accepts a public https callback_url" do
  session = build(:scribe_session, callback_url: "https://client.example.com/webhook")
  assert session.valid?
end

test "accepts a blank callback_url" do
  session = build(:scribe_session, callback_url: nil)
  assert session.valid?
end
```

In `test/jobs/scribe_webhook_job_test.rb`, add a timeout test using mocha to
capture the Faraday request block (model after the existing `build_session`
helper in that file). Add `require "ostruct"` near the top if not present:
```ruby
test "configures explicit open and read timeouts on the webhook request" do
  captured = OpenStruct.new(headers: {}, options: OpenStruct.new)
  Faraday.stubs(:post).yields(captured).returns(true)

  session = build_session(callback_url: "https://client.example.com/webhook")
  ScribeWebhookJob.perform_now(session.id)

  assert_equal ScribeWebhookJob::OPEN_TIMEOUT_SECONDS, captured.options.open_timeout
  assert_equal ScribeWebhookJob::READ_TIMEOUT_SECONDS, captured.options.timeout
end
```

**Verify**:
`ASDF_RUBY_VERSION=3.2.2 bin/rails test test/models/scribe_session_test.rb test/jobs/scribe_webhook_job_test.rb`
→ all pass, including the new tests. Confirm the existing job tests
("POSTs a signed JSON body…", "swallows Faraday transport errors…") still pass —
they use `https://client.example.com`, which the validation allows.

## Test plan

- New tests in `test/models/scribe_session_test.rb`: reject non-https, loopback,
  metadata (169.254.169.254), and RFC-1918 callback URLs; accept a public https
  URL and a blank URL. These are the exact SSRF inputs the plan blocks.
- New test in `test/jobs/scribe_webhook_job_test.rb`: asserts `open_timeout` /
  `timeout` are set on the Faraday request (mocha `yields` an `OpenStruct` request
  double). webmock still backs the other job tests.
- Structural patterns: `test/models/scribe_session_test.rb` (validity assertions
  via `build(:scribe_session, ...)`) and the `build_session` helper in
  `test/jobs/scribe_webhook_job_test.rb`.
- Verification: `ASDF_RUBY_VERSION=3.2.2 bin/rails test` → 0 failures.

## Done criteria

Machine-checkable. ALL must hold:

- [ ] `grep -n "callback_url_is_safe\|BLOCKED_IP_RANGES" app/models/scribe_session.rb` shows the validation + constant
- [ ] `grep -n "session.valid?" app/controllers/api/v2/scribe_sessions_controller.rb` returns one match before `session.save!`
- [ ] `grep -n "open_timeout\|timeout =" app/jobs/scribe_webhook_job.rb` shows both timeout assignments
- [ ] `ASDF_RUBY_VERSION=3.2.2 bin/rails test` exits 0; the new model + job tests are present and passing
- [ ] `ASDF_RUBY_VERSION=3.2.2 bin/rubocop` reports no offenses
- [ ] `ASDF_RUBY_VERSION=3.2.2 bin/brakeman --no-pager` reports no new warnings (and ideally clears any existing SSRF warning for this sink)
- [ ] No files outside the in-scope list are modified (`git status`)
- [ ] `plans/README.md` status row updated

## STOP conditions

Stop and report back (do not improvise) if:

- The code at any "Current state" location does not match the excerpt (drift).
- The existing job tests fail after Step 1 because `https://client.example.com`
  is being rejected — that means DNS in your environment resolves that host to a
  routable/blocked address; report it rather than loosening the validation.
- `session.valid?` in Step 2 rejects a session for a reason OTHER than
  `callback_url` (e.g. an unexpected required attribute) — the generic 422 would
  then mask a real bug; report the full `errors` instead of shipping.
- Adding the model validation makes an unrelated existing test fail (some other
  spec sets a private/non-https `callback_url` you were not told about).

## Maintenance notes

For the human/agent who owns this after the change lands:

- **Follow-up (deferred)**: a per-account host **allowlist** is the stronger
  control — restrict `callback_url` hosts to values the account pre-registered.
  This plan only blocks obviously-internal targets.
- **DNS-rebinding / TOCTOU**: validation resolves DNS at create time; a hostname
  could resolve public then flip to private before the job runs. Fully closing
  that requires pinning the resolved IP and connecting to it (or an egress proxy).
  Out of scope here; note it for a future hardening pass.
- The "unresolvable host is allowed" choice is deliberate (keeps
  `client.example.com` test fixtures valid and cannot reach internal services);
  a reviewer should confirm they accept it.
- The webhook timeouts (5s open / 10s read) are conservative defaults; tune if
  legitimate consumer endpoints are slower, but never remove them.
