# Plan 004: Make commit idempotent so re-committing never double-charges

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan
> in `plans/README.md` — unless a reviewer dispatched you and told you they
> maintain the index.
>
> **Drift check (run first)**:
> `git diff --stat 84da325..HEAD -- app/controllers/api/v2/scribe_sessions_controller.rb app/controllers/api/v2/base_controller.rb app/services/metering/usage_recorder.rb app/services/scribe/orchestrator.rb`
> If any in-scope file changed since this plan was written, compare the
> "Current state" excerpts against the live code before proceeding; on a
> mismatch, treat it as a STOP condition.

## Status

- **Priority**: P1
- **Effort**: M
- **Risk**: MED
- **Depends on**: plans/002-enforce-quota-at-commit.md (soft — 004 works
  independently but shares the commit action; land 002 first to avoid conflicts)
- **Category**: bug
- **Planned at**: commit `84da325`, 2026-07-08

## Why this matters

Re-committing a scribe session **double-charges** it. `commit` has no
`session.status` guard, so a client (or a retry) can POST `/commit` twice; each
call enqueues a fresh `ProcessScribeSessionJob`, which re-runs the whole pipeline
and re-meters every output. The header-based idempotency helper is a **no-op
unless the client sends an `Idempotency-Key`**, and the unique
`(api_token_id, dedupe_key)` index on `usage_events` is inert because the
orchestrator never passes a `dedupe_key` (NULLs are distinct in Postgres). After
this plan, a duplicate commit runs the pipeline at most once, re-committing a
`failed`/`partial` session retries only the failed outputs, and the unique index
actually dedupes retried finalizes so no output is charged twice.

## Current state

Files involved and their roles:

- `app/controllers/api/v2/scribe_sessions_controller.rb` — the commit endpoint;
  no status guard.
- `app/controllers/api/v2/base_controller.rb` — `with_idempotency`, a no-op
  without the header.
- `app/services/metering/usage_recorder.rb` — `record(... dedupe_key: nil)`;
  writes the `usage_events.dedupe_key` column.
- `app/services/scribe/orchestrator.rb` — reprocesses every output regardless of
  status, and calls `UsageRecorder.record` without a `dedupe_key`.
- `db/schema.rb` — the unique `(api_token_id, dedupe_key)` index.

No status guard on commit, `app/controllers/api/v2/scribe_sessions_controller.rb:45-63`:

```ruby
# POST /api/v2/scribe_sessions/:id/commit
def commit
  session = find_session
  return unless session

  if session.expired?
    render_error(code: "session_expired", message: "Scribe session has expired", status: :gone)
    return
  end

  fingerprint = "commit:#{session.id}"
  with_idempotency(fingerprint) do
    Metering::QuotaGuard.hold!(account: current_account, estimate: 0)
    session.update!(status: "processing")
    ProcessScribeSessionJob.perform_later(session.id)

    render json: serialize(session), status: :accepted
  end
end
```

`with_idempotency` is a no-op without the header,
`app/controllers/api/v2/base_controller.rb:53-55`:

```ruby
def with_idempotency(fingerprint)
  key = idempotency_key_header
  return yield if key.blank?
```

`UsageRecorder.record` defaults `dedupe_key: nil` and writes it,
`app/services/metering/usage_recorder.rb:8-9` and `:41`:

```ruby
def record(account:, function:, result:, api_token: nil, scribe_session: nil,
           scribe_output: nil, status: :finalized, dedupe_key: nil)
```

```ruby
    dedupe_key: dedupe_key
  )
```

The orchestrator never passes a `dedupe_key`,
`app/services/scribe/orchestrator.rb:233-244`:

```ruby
def record_and_deduct(function:, stage:, scribe_output: nil)
  event = Metering::UsageRecorder.record(
    account: session.account,
    function: function,
    result: as_llm_result(stage),
    api_token: session.api_token,
    scribe_session: session,
    scribe_output: scribe_output
  )
  Metering::QuotaGuard.deduct!(event)
  event
end
```

The orchestrator loop reprocesses every output regardless of prior success,
`app/services/scribe/orchestrator.rb:39-45`:

```ruby
@session.scribe_outputs.each do |output|
  stage = process_output(output, transcript)
  # Metering is best-effort and runs OUTSIDE the per-output rescue ...
  meter_output(output, stage) if stage
end
```

The inert unique index, `db/schema.rb:311`:

```ruby
t.index ["api_token_id", "dedupe_key"], name: "index_usage_events_on_token_and_dedupe_key", unique: true
```

(Inert because every `dedupe_key` is currently NULL, and Postgres treats NULLs as
distinct — the unique index never fires.)

**Relevant facts (verified during recon):**
- `ScribeSession` statuses: `created, uploading, processing, completed, partial,
  failed, expired` (`app/models/scribe_session.rb:11-19`).
- `ScribeOutput` status enum is prefixed: `status_pending?`, `status_success?`,
  `status_partial?`, `status_failure?` (`app/models/scribe_output.rb`).
- Test env runs jobs **inline** (`config/environments/test.rb:27`), so a commit
  request runs the orchestrator synchronously — a second commit that enqueues a
  second job would run the pipeline again in-request.
- Idempotency helper uses `next` inside the block (the `create` action does this
  at `scribe_sessions_controller.rb:17-18`).

## Commands you will need

| Purpose | Command | Expected on success |
|---|---|---|
| Prepare test DB | `ASDF_RUBY_VERSION=3.2.2 bin/rails db:test:prepare` | exit 0 |
| Controller test | `ASDF_RUBY_VERSION=3.2.2 bin/rails test test/integration/api/v2/scribe_sessions_test.rb` | 0 failures |
| Orchestrator test | `ASDF_RUBY_VERSION=3.2.2 bin/rails test test/services/scribe/orchestrator_test.rb` | 0 failures |
| Tests (all) | `ASDF_RUBY_VERSION=3.2.2 bin/rails test` | 0 failures |
| Lint | `ASDF_RUBY_VERSION=3.2.2 bin/rubocop` | no offenses |

(The `ASDF_RUBY_VERSION=3.2.2` prefix is required so asdf resolves Ruby 3.2.2.)

## Scope

**In scope** (the only files you should modify):
- `app/controllers/api/v2/scribe_sessions_controller.rb` (status guard on commit)
- `app/services/scribe/orchestrator.rb` (skip already-successful outputs; pass a
  deterministic `dedupe_key`)
- `test/integration/api/v2/scribe_sessions_test.rb` (extend)
- `test/services/scribe/orchestrator_test.rb` (extend)

**Out of scope** (do NOT touch):
- `app/services/metering/usage_recorder.rb` — it already accepts and persists
  `dedupe_key`; no change needed. The orchestrator just has to pass one.
- `app/controllers/api/v2/base_controller.rb` — `with_idempotency` is correct for
  header-based idempotency; this plan adds a status guard, not a header rework.
- `db/schema.rb` / migrations — the unique `(api_token_id, dedupe_key)` index
  already exists; do NOT add or alter indexes.
- The metering best-effort boundary and `QuotaGuard.deduct!` idempotency (unique
  `(usage_event_id, txn_type)` index) — preserve both.

## Git workflow

- Branch: `advisor/004-idempotent-commit`
- Commit per logical unit; short imperative messages like the repo log
  (e.g. `Guard commit against re-processing`, `Dedupe metering on retry`).
- Do NOT push or open a PR unless the operator instructed it.

## Steps

### Step 1: Guard `commit` against re-processing an in-flight/terminal session

In `app/controllers/api/v2/scribe_sessions_controller.rb`, reject a commit unless
the session is in a commit-able state, while still ALLOWING a retry of a
`failed`/`partial` session. Allowed-to-commit states:

- `created`, `uploading` → first commit (proceed).
- `failed`, `partial` → re-commit to retry only failed outputs (proceed; the
  orchestrator changes in Step 2 make this charge only the retried outputs).
- `processing` → reject: already in flight. Return a stable error (reuse
  `validation_error` with a clear message, or add `session_not_committable` — pick
  one and be consistent; `validation_error` avoids adding a code). Suggested:
  `409 Conflict`.
- `completed` → reject as already done (same error/status as `processing`), OR
  replay the stored result — choose "reject" for simplicity unless the maintainer
  wants replay.
- `expired` → already handled by the existing `expired?` check.

Target shape (place the guard after the `expired?` check, before
`with_idempotency`):

```ruby
unless session.status_created? || session.status_uploading? ||
       session.failed? || session.partial?
  render_error(
    code: "validation_error",
    message: "Session cannot be committed from status #{session.status}",
    status: :conflict
  )
  return
end
```

Note: `ScribeSession` uses `enum :status` WITHOUT a prefix, so the predicates are
`session.created?`, `session.uploading?`, `session.processing?`, `completed?`,
`partial?`, `failed?`, `expired?` (verify against
`app/models/scribe_session.rb:11-19`). Use the correct predicate names.

**Verify**: `ASDF_RUBY_VERSION=3.2.2 bin/rails test test/integration/api/v2/scribe_sessions_test.rb`
→ existing full-lifecycle test still passes (it commits once from `uploading`).

### Step 2: Skip already-successful outputs on re-run

In `app/services/scribe/orchestrator.rb`, in the `call` loop
(`orchestrator.rb:39-45`), skip outputs that are already `status_success?` so a
re-commit only reprocesses failed/partial/pending outputs and does not re-meter
successes. Target shape:

```ruby
@session.scribe_outputs.each do |output|
  next if output.status_success?

  stage = process_output(output, transcript)
  meter_output(output, stage) if stage
end
```

Keep the transcript reuse (`ensure_transcript!` already returns the existing
transcript without re-running ASR — `orchestrator.rb:58-59`), so a re-run does
not re-charge ASR either.

**Verify**: `ASDF_RUBY_VERSION=3.2.2 bin/rails test test/services/scribe/orchestrator_test.rb`
→ existing tests pass (fresh sessions have all `pending` outputs, so nothing is
skipped on the first run).

### Step 3: Pass a deterministic `dedupe_key` into `UsageRecorder.record`

In `app/services/scribe/orchestrator.rb`, `record_and_deduct`
(`orchestrator.rb:233-244`), pass a deterministic `dedupe_key` so the unique
`(api_token_id, dedupe_key)` index turns a retried finalize into a no-op instead
of a duplicate `UsageEvent`. Keys:

- Per structuring output: `"#{session.id}:#{scribe_output&.id}:#{function}"`.
- Session-level ASR (no output): `"#{session.id}:asr"`.

Target shape:

```ruby
def record_and_deduct(function:, stage:, scribe_output: nil)
  event = Metering::UsageRecorder.record(
    account: session.account,
    function: function,
    result: as_llm_result(stage),
    api_token: session.api_token,
    scribe_session: session,
    scribe_output: scribe_output,
    dedupe_key: dedupe_key_for(function, scribe_output)
  )
  Metering::QuotaGuard.deduct!(event)
  event
end

def dedupe_key_for(function, scribe_output)
  scribe_output ? "#{session.id}:#{scribe_output.id}:#{function}" : "#{session.id}:#{function}"
end
```

**Important:** `UsageRecorder.record` uses `UsageEvent.create!`. A duplicate
`dedupe_key` will now raise `ActiveRecord::RecordNotUnique`. That raise happens
inside the orchestrator's best-effort `meter` rescue
(`orchestrator.rb:216-224`, which rescues `StandardError` and swallows it), so a
duplicate finalize is safely turned into a logged no-op — it does NOT demote the
output or fail the session. Confirm the rescue covers this path; do NOT add a
second rescue that changes the best-effort semantics. If Step 2 already prevents
re-metering successful outputs, this index is the belt-and-suspenders guard for
concurrent/retried finalizes.

**Verify**: `ASDF_RUBY_VERSION=3.2.2 bin/rails test test/services/scribe/orchestrator_test.rb`
→ all pass (the `UsageEvent.count` assertions still hold on a single run because
each key is unique per run).

### Step 4: Add tests (see Test plan), then run everything

**Verify**: `ASDF_RUBY_VERSION=3.2.2 bin/rails test` → 0 failures.

## Test plan

**Controller** — add to `test/integration/api/v2/scribe_sessions_test.rb` (model
after the "full lifecycle: create -> audio -> commit -> completed show" test at
lines 31–64; jobs run inline so the pipeline executes in-request):

- **"committing twice runs the pipeline once and charges each output once"**:
  run create → audio → commit as the lifecycle test does; the session ends
  `completed`. Then POST `/commit` a second time and assert:
  - the second commit is rejected (`assert_response :conflict`) because status is
    `completed` — OR, if the maintainer chose replay, assert no new
    `UsageEvent`s.
  - `UsageEvent.where(scribe_session_id: session_id).count` is unchanged between
    the first and second commit (one `asr` + one `structuring` for the single
    form output).
- Optionally, **"re-committing a failed session retries only failed outputs"**:
  requires forcing a first-run failure (e.g. stub the chat endpoint to 500 on the
  first commit, then 200 on the retry). If this is hard to set up deterministically
  in the integration test, cover the "skip successful outputs" behavior in the
  orchestrator unit test instead (below) and note it.

**Orchestrator** — add to `test/services/scribe/orchestrator_test.rb` (model
after "runs ASR once, fills transcript + form outputs, records usage" at lines
47–90; it already stubs ASR/chat and counts `UsageEvent`s):

- **"re-running the orchestrator does not re-meter an already-successful output"**:
  run `Scribe::Orchestrator.new(session).call` once (asserts 2 usage events via
  `assert_difference("UsageEvent.count", 2)`), then run it a **second** time and
  assert `assert_no_difference("UsageEvent.count") { Scribe::Orchestrator.new(session.reload).call }`
  — the successful outputs are skipped (Step 2) and ASR is reused, so no new
  events. This also exercises the `dedupe_key` guard.

Verification: `ASDF_RUBY_VERSION=3.2.2 bin/rails test test/integration/api/v2/scribe_sessions_test.rb test/services/scribe/orchestrator_test.rb`
→ all pass, including the new tests.

## Done criteria

Machine-checkable. ALL must hold:

- [ ] `ASDF_RUBY_VERSION=3.2.2 bin/rails test` → 0 failures, includes the
      double-commit and re-run no-op tests
- [ ] `ASDF_RUBY_VERSION=3.2.2 bin/rubocop` → no offenses
- [ ] `grep -n "dedupe_key" app/services/scribe/orchestrator.rb` → present (the
      orchestrator now passes a key)
- [ ] `grep -n "status_success?" app/services/scribe/orchestrator.rb` → present in
      the `call` loop (successful outputs skipped)
- [ ] A commit from `processing`/`completed` is rejected (covered by the new test)
- [ ] No files outside the in-scope list are modified (`git status`)
- [ ] `plans/README.md` status row updated

## STOP conditions

Stop and report back (do not improvise) if:

- The "Current state" excerpts don't match live code (drift since `84da325`).
- The allowed re-commit states are unclear for the product (e.g. whether
  `completed` should replay vs reject) — confirm with the maintainer rather than
  guessing; a wrong guard either blocks legitimate retries or permits
  double-charge.
- Passing a `dedupe_key` causes an existing orchestrator test to fail in a way
  that suggests the best-effort `meter` rescue does NOT cover
  `ActiveRecord::RecordNotUnique` (it should — `orchestrator.rb:216-224` rescues
  `StandardError`). If a duplicate finalize demotes an output or fails a session,
  STOP — that violates the by-design metering boundary.
- The fix appears to require editing `usage_recorder.rb`, `base_controller.rb`,
  or a migration (all out of scope).
- A verification fails twice after a reasonable fix attempt.

## Maintenance notes

For whoever owns this after it lands:

- The `dedupe_key` format `"session:output:function"` (and `"session:asr"`) is
  now a stable contract for the unique index. If ASR ever becomes per-output or
  functions are renamed, revisit the key so retries still dedupe.
- The unique index is scoped to `(api_token_id, dedupe_key)`. If a session could
  ever be metered under a different `api_token`, the dedupe would not fire across
  tokens — confirm sessions keep a single `api_token`.
- Reviewer should scrutinize: the status guard allows `failed`/`partial` retries
  but blocks `processing`; the re-run skips only `status_success?` outputs (not
  `partial`, which should retry); and the duplicate-`UsageEvent` `RecordNotUnique`
  is swallowed by the existing best-effort `meter` rescue without demoting a
  finalized output (regression tests at `orchestrator_test.rb:225-257` stay green).
- Interacts with plan 002 (shares the commit action) and plan 003 (reservation
  settlement must also be idempotent under retried commits).
