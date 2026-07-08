# Plan 012: Make the scribe webhook `delivery_id` stable across delivery retries

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan
> in `plans/README.md` — unless a reviewer dispatched you and told you they
> maintain the index.
>
> **Drift check (run first)**:
> `git diff --stat 84da325..HEAD -- app/jobs/scribe_webhook_job.rb test/jobs/scribe_webhook_job_test.rb`
> If any in-scope file changed since this plan was written, compare the
> "Current state" excerpts against the live code before proceeding; on a
> mismatch, treat it as a STOP condition.

## Status

- **Priority**: P2
- **Effort**: S
- **Risk**: LOW
- **Depends on**: none
- **Category**: bug
- **Planned at**: commit `84da325`, 2026-07-08

## Why this matters

The completion webhook carries a `delivery_id` so consumers can deduplicate
retried deliveries. Today that id is regenerated with `SecureRandom.uuid` on
**every** `perform`, and delivery is at-least-once (Faraday transport errors are
swallowed so ActiveJob replays the job). So the same logical delivery arrives at
the consumer with a *different* `delivery_id` each retry, which defeats dedupe
entirely — a consumer that received a delivery, then gets the retry, sees a
brand-new id and processes it twice. The fix makes the id deterministic for a
given (session, status) so retries repeat it.

## Current state

- `app/jobs/scribe_webhook_job.rb` — delivers the completion webhook. The job
  builds a fresh payload every `perform`:

  `app/jobs/scribe_webhook_job.rb:15-34` (`perform` calls `build_payload` each run):
  ```ruby
  def perform(scribe_session_id)
    session = ScribeSession.find_by(id: scribe_session_id)
    return if session.nil?
    return if session.callback_url.blank?

    payload = build_payload(session)
    json = payload.to_json
    timestamp = Time.now.to_i
    signature = Scribe::WebhookSigner.signature(...)
    deliver(session.callback_url, json, signature)
  rescue Faraday::Error => e
    Rails.logger.warn("ScribeWebhookJob delivery failed for session=#{scribe_session_id}: #{e.class}: #{e.message}")
    nil
  end
  ```

  `app/jobs/scribe_webhook_job.rb:38-49` — the offending line is the
  `delivery_id:` value inside `build_payload`:
  ```ruby
  def build_payload(session)
    {
      session_id: session.id,
      status: session.status,
      outputs: session.scribe_outputs.map do |output|
        { id: output.id, output_type: output.output_type, status: output.status }
      end,
      delivery_id: SecureRandom.uuid,   # <- regenerated every perform
      sent_at: Time.now.utc.iso8601
    }
  end
  ```

- The at-least-once contract that makes this a bug — `app/jobs/scribe_webhook_job.rb:12-13`
  (class doc) and `:31-34` (the rescue that swallows transport errors so
  ActiveJob retries): the SAME job runs again, so a stable payload field must
  not change between runs.

- `ScribeSession#status` is an enum backed by a string column
  (`app/models/scribe_session.rb:11-19`), values include `completed`, `partial`,
  `failed`, etc. `session.id` is the primary key. Both are stable within a
  status.

- The existing test file `test/jobs/scribe_webhook_job_test.rb` already sets up
  the retry scenario in the test "swallows Faraday transport errors so delivery
  can be retried" (`:71-78`) and asserts the payload allowlist in "body carries
  only the PHI-light allowlist" (`:40-59`, which asserts
  `parsed.keys.sort == %w[delivery_id outputs sent_at session_id status]`).

- **No** `delivery_id` column exists on `scribe_sessions` (see
  `db/schema.rb` `create_table "scribe_sessions"`), so the recommended fix
  (Path A below) is derivation, requiring no migration.

## Commands you will need

| Purpose        | Command                                                                 | Expected on success |
|----------------|-------------------------------------------------------------------------|---------------------|
| Single test    | `ASDF_RUBY_VERSION=3.2.2 bin/rails test test/jobs/scribe_webhook_job_test.rb` | all pass       |
| Full tests     | `ASDF_RUBY_VERSION=3.2.2 bin/rails test`                                 | 0 failures          |
| Lint           | `ASDF_RUBY_VERSION=3.2.2 bin/rubocop app/jobs/scribe_webhook_job.rb`     | no offenses         |

## Scope

**In scope** (the only files you should modify):
- `app/jobs/scribe_webhook_job.rb`
- `test/jobs/scribe_webhook_job_test.rb`

**Out of scope** (do NOT touch, even though they look related):
- `app/services/scribe/webhook_signer.rb` — the signature is intentionally over
  a per-attempt timestamp (`t=<unix>`); do NOT try to make the signature stable,
  only the `delivery_id`. These are different fields with different lifetimes.
- The payload allowlist keys — do NOT add or rename keys; the PHI-light contract
  in the class doc (`:2-7`) and the test at `:53` depend on exactly
  `%w[delivery_id outputs sent_at session_id status]`.
- Any migration / `scribe_sessions` schema change (that is the alternative
  Path B, which this plan does NOT take unless the STOP note directs it).

## Git workflow

- Branch: `advisor/012-stable-webhook-delivery-id`
- One commit; short imperative subject (e.g.
  `Derive a stable webhook delivery_id per session+status`).
- Do NOT push or open a PR unless the operator instructed it.

## Steps

### Step 1 (recommended — Path A): Derive `delivery_id` deterministically

Replace the `delivery_id: SecureRandom.uuid` line in `build_payload` with a
deterministic UUID v5 derived from the session id and status, so every retry of
the same logical delivery produces the identical id.

Target shape in `app/jobs/scribe_webhook_job.rb`:
```ruby
# Stable per (session, status): ActiveJob retries of the same logical delivery
# repeat this id so consumers can dedupe. A later status change is a new
# logical delivery and correctly yields a new id.
def build_payload(session)
  {
    session_id: session.id,
    status: session.status,
    outputs: session.scribe_outputs.map do |output|
      { id: output.id, output_type: output.output_type, status: output.status }
    end,
    delivery_id: delivery_id_for(session),
    sent_at: Time.now.utc.iso8601
  }
end

def delivery_id_for(session)
  Digest::UUID.uuid_v5(
    Digest::UUID::OID_NAMESPACE,
    "scribe-session:#{session.id}:#{session.status}"
  )
end
```

`Digest::UUID` ships with ActiveSupport and is autoloaded in a booted Rails app.
If a `NameError: uninitialized constant Digest::UUID` occurs when the test runs,
add `require "digest/uuid"` at the top of the job file (below the class doc) and
re-run — do not switch approaches.

**Verify**:
`ASDF_RUBY_VERSION=3.2.2 bin/rails test test/jobs/scribe_webhook_job_test.rb`
→ all existing tests still pass (the allowlist test still sees a `delivery_id`
key with a UUID-shaped value).

### Step 2: Add a regression test proving the id is stable across two performs

In `test/jobs/scribe_webhook_job_test.rb`, add a test that performs the job
twice against the same session and asserts identical `delivery_id`. Model it on
the existing "body carries only the PHI-light allowlist" test (`:40-59`) for the
stub + body-capture pattern.

Target shape:
```ruby
test "delivery_id is stable across retries of the same delivery" do
  callback_url = "https://client.example.com/webhook"
  bodies = []
  stub_request(:post, callback_url).to_return do |req|
    bodies << req.body
    { status: 200, body: "" }
  end

  session = build_session(callback_url: callback_url)

  ScribeWebhookJob.perform_now(session.id)
  ScribeWebhookJob.perform_now(session.id)

  first  = JSON.parse(bodies[0])["delivery_id"]
  second = JSON.parse(bodies[1])["delivery_id"]
  assert_equal first, second
  assert_match(/\A[0-9a-f-]{36}\z/, first)
end
```

**Verify**:
`ASDF_RUBY_VERSION=3.2.2 bin/rails test test/jobs/scribe_webhook_job_test.rb`
→ all pass, including the new test. Then confirm the new test actually guards
the bug: temporarily reverting Step 1 to `SecureRandom.uuid` makes ONLY the new
test fail; restore Step 1 afterward.

## Test plan

- New test in `test/jobs/scribe_webhook_job_test.rb`:
  - "delivery_id is stable across retries of the same delivery" — performs the
    job twice, asserts the two captured `delivery_id` values are equal and
    UUID-shaped. This is the exact regression the plan fixes.
- Structural pattern to follow: the existing tests in the same file (stub with a
  block that captures `req.body`, then `JSON.parse`).
- Verification: `ASDF_RUBY_VERSION=3.2.2 bin/rails test test/jobs/scribe_webhook_job_test.rb`
  → all pass, including 1 new test.

## Done criteria

Machine-checkable. ALL must hold:

- [ ] `grep -n "SecureRandom.uuid" app/jobs/scribe_webhook_job.rb` returns no matches
- [ ] `ASDF_RUBY_VERSION=3.2.2 bin/rails test test/jobs/scribe_webhook_job_test.rb` passes, with the new stability test present and passing
- [ ] `ASDF_RUBY_VERSION=3.2.2 bin/rails test` exits 0 with 0 failures
- [ ] `ASDF_RUBY_VERSION=3.2.2 bin/rubocop app/jobs/scribe_webhook_job.rb` reports no offenses
- [ ] The payload keys are still exactly `%w[delivery_id outputs sent_at session_id status]` (the existing allowlist test still passes)
- [ ] No files outside the in-scope list are modified (`git status`)
- [ ] `plans/README.md` status row updated

## STOP conditions

Stop and report back (do not improvise) if:

- The code at `app/jobs/scribe_webhook_job.rb:38-49` does not match the
  "Current state" excerpt (drift).
- You determine the job is enqueued **more than once per (session, status)** for
  genuinely distinct logical deliveries that must NOT dedupe together — in that
  case the (session, status) derivation is too coarse and you should instead
  persist a `delivery_id` column (Path B: migration + set-once-on-first-build).
  Report this rather than silently switching approaches.
- `Digest::UUID` is unavailable even after adding `require "digest/uuid"`.

## Maintenance notes

For the human/agent who owns this after the change lands:

- The id granularity is **one delivery_id per (session, status)**. If a future
  change sends multiple intentionally-distinct webhooks at the *same* status
  (e.g. a manual re-notify that should NOT dedupe), this derivation will collapse
  them — switch to a persisted per-delivery column (Path B) at that point.
- A reviewer should confirm: retries repeat the id (the new test), and a status
  transition still yields a *new* id (that is intended — it is a new logical
  delivery), and the PHI-light allowlist is unchanged.
- Path B (deferred): add a nullable `delivery_id` string column to
  `scribe_sessions`, set it once on first webhook build, and read it thereafter.
  Only do this if the STOP condition about multiple same-status deliveries fires.
