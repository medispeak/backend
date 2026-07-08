# Plan 002: Enforce the credit quota at commit (make the inert quota gate actually block)

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan
> in `plans/README.md` — unless a reviewer dispatched you and told you they
> maintain the index.
>
> **Drift check (run first)**:
> `git diff --stat 84da325..HEAD -- app/controllers/api/v2/scribe_sessions_controller.rb app/services/metering/quota_guard.rb app/models/account_credit.rb`
> If any in-scope file changed since this plan was written, compare the
> "Current state" excerpts against the live code before proceeding; on a
> mismatch, treat it as a STOP condition.

## Status

- **Priority**: P1
- **Effort**: M
- **Risk**: MED
- **Depends on**: plans/001-meter-asr-audio-duration.md (soft — 001 gives a real
  estimate for `hold!`; this plan works without it using a zero-balance reject)
- **Category**: security
- **Planned at**: commit `84da325`, 2026-07-08

## Why this matters

The credit quota gate at commit is **inert**: the controller calls
`QuotaGuard.hold!` with `estimate: 0`, throws the returned token away, and never
checks whether the hold succeeded before enqueuing the (billable) job. An account
with a zero — or negative — credit balance can commit unlimited scribe sessions
and run up provider cost with no enforcement. After this plan, `commit` computes
a real estimate, refuses the request with a stable `insufficient_credit` /
`402 Payment Required` error when the account lacks credit, and `deduct!` never
silently drives a balance below the agreed floor. The by-design "no
`AccountCredit` row = unlimited" behavior is preserved.

## Current state

Files involved and their roles:

- `app/controllers/api/v2/scribe_sessions_controller.rb` — the v2 commit endpoint;
  where the hold result is discarded.
- `app/services/metering/quota_guard.rb` — ledger enforcement; `hold!` returns a
  `Token` (`ok?`), `deduct!`/`apply_settlement` mutate balance with no floor.
- `app/models/account_credit.rb` — the ledger row; today validates only presence
  of `balance`.
- `app/controllers/api/v2/base_controller.rb` — `render_error(code:, message:,
  status:, details:)` envelope and the list of existing codes (read-only reference).

The discarded hold, `app/controllers/api/v2/scribe_sessions_controller.rb:46-63`:

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

`hold!` already returns a checkable `Token`, `app/services/metering/quota_guard.rb:25-46`:

```ruby
def hold!(account:, estimate:)
  credit = AccountCredit.find_by(account_id: account.id)
  return Token.new(ok: true, transaction: nil, unlimited: true) if credit.nil?

  estimate = estimate.to_d

  AccountCredit.transaction do
    credit.lock!
    if credit.balance - estimate < 0
      return Token.new(ok: false, transaction: nil, unlimited: false)
    end

    txn = CreditTransaction.create!(
      account_id: account.id,
      txn_type: :hold,
      amount: estimate,
      balance_before: credit.balance,
      balance_after: credit.balance
    )
    Token.new(ok: true, transaction: txn, unlimited: false)
  end
end
```

`deduct!` has no floor — `apply_settlement` will persist a negative balance,
`app/services/metering/quota_guard.rb:48-56` and `:60-85`:

```ruby
def deduct!(usage_event)
  amount = usage_event.cost.to_d
  apply_settlement(usage_event, :deduction, amount, sign: -1)
end
```

```ruby
def apply_settlement(usage_event, txn_type, amount, sign:)
  credit = AccountCredit.find_by(account_id: usage_event.account_id)
  return nil if credit.nil?

  AccountCredit.transaction(requires_new: true) do
    credit.lock!
    balance_before = credit.balance
    balance_after = balance_before + (amount * sign)   # <- can go below 0
    ...
    credit.update!(balance: balance_after)
```

`AccountCredit` validates only presence, `app/models/account_credit.rb:1-6`:

```ruby
class AccountCredit < ApplicationRecord
  belongs_to :account

  validates :account_id, uniqueness: true
  validates :balance, presence: true
end
```

**By-design invariants you MUST preserve** (verified in the code + tests):

- Accounts with **no** `AccountCredit` row are unlimited: `hold!` returns an
  `unlimited` ok token, `deduct!`/`refund!` no-op (`quota_guard.rb:27`, `:65`).
  Do not break this — see `quota_guard_test.rb` "hold is a no-op unlimited
  token when no AccountCredit exists" and "deduct no-ops gracefully…".
- The `AccountCredit` `balance` column is `decimal precision: 16, scale: 6,
  default 0.0, null: false` (`db/schema.rb:19`). Money is `BigDecimal` — use
  `.to_d`.

**Existing v2 error codes** (from `base_controller.rb` usage + the repo
conventions): `validation_error`, `session_not_found`, `session_expired`,
`rate_limited`, `internal_error`. You will add a new one: `insufficient_credit`
with HTTP `402 Payment Required`. Keep codes as stable lowercase strings.

**Test gap:** the current commit integration test
(`test/integration/api/v2/scribe_sessions_test.rb:31-64`) never creates an
`AccountCredit`, so the account is "unlimited" and the gate is never exercised.

## Commands you will need

| Purpose | Command | Expected on success |
|---|---|---|
| Prepare test DB | `ASDF_RUBY_VERSION=3.2.2 bin/rails db:test:prepare` | exit 0 |
| Controller test | `ASDF_RUBY_VERSION=3.2.2 bin/rails test test/integration/api/v2/scribe_sessions_test.rb` | 0 failures |
| QuotaGuard test | `ASDF_RUBY_VERSION=3.2.2 bin/rails test test/services/metering/quota_guard_test.rb` | 0 failures |
| Tests (all) | `ASDF_RUBY_VERSION=3.2.2 bin/rails test` | 0 failures |
| Lint | `ASDF_RUBY_VERSION=3.2.2 bin/rubocop` | no offenses |

(The `ASDF_RUBY_VERSION=3.2.2` prefix is required so asdf resolves Ruby 3.2.2.)

## Scope

**In scope** (the only files you should modify):
- `app/controllers/api/v2/scribe_sessions_controller.rb`
- `app/services/metering/quota_guard.rb`
- `test/integration/api/v2/scribe_sessions_test.rb`
- `test/services/metering/quota_guard_test.rb`

**Out of scope** (do NOT touch):
- `app/services/scribe/orchestrator.rb` — its post-processing `deduct!` calls are
  reserved for plan 003/004; do not re-wire them here.
- `db/schema.rb` / migrations — do NOT add a DB-level balance check constraint in
  this plan; the floor is enforced in `deduct!`. (A CHECK constraint can be a
  plan-003 follow-up.)
- The unlimited-when-no-`AccountCredit` behavior — must remain intact.

## Git workflow

- Branch: `advisor/002-enforce-quota-at-commit`
- Commit per logical unit; short imperative messages like the repo log
  (e.g. `Enforce credit quota at commit`, `Floor deduct! at zero balance`).
- Do NOT push or open a PR unless the operator instructed it.

## Steps

### Step 0 (DECISION GATE — confirm with the maintainer before coding)

This plan changes billing behavior. Two decisions must be confirmed; surface
them and STOP if the maintainer has not answered:

1. **Hard-block vs. overdraft-with-alert at zero balance.** This plan implements
   **hard-block**: reject commit when the account has an `AccountCredit` and the
   hold cannot be covered. If the maintainer wants overdraft-with-alert instead,
   STOP — the response shape and floor differ.
2. **Reserve-vs-postpaid.** This plan is the immediate guard: `hold!` is checked
   but (per current `hold!` code) does not yet decrement `balance` — true
   reservation accounting is **plan 003**. Confirm plan 003 will follow; the
   `deduct!` floor added here must stay consistent with whatever 003 chooses.

Record the answers in the PR description. Do not proceed past this gate on
assumptions.

### Step 1: Compute a real estimate and check the hold in `commit`

In `app/controllers/api/v2/scribe_sessions_controller.rb`, replace the discarded
`hold!` with a checked hold **before** `update!(status: "processing")` and
`perform_later`. Target shape:

```ruby
with_idempotency(fingerprint) do
  token = Metering::QuotaGuard.hold!(account: current_account, estimate: commit_estimate(session))
  unless token.ok?
    render_error(
      code: "insufficient_credit",
      message: "Account has insufficient credit to process this session",
      status: :payment_required
    )
    next
  end

  session.update!(status: "processing")
  ProcessScribeSessionJob.perform_later(session.id)

  render json: serialize(session), status: :accepted
end
```

Note: use `next` (not `return`) inside the `with_idempotency` block — it yields a
block, matching the existing `create` action which uses `next` on validation
error (`scribe_sessions_controller.rb:17-18`).

Add a private `commit_estimate(session)` helper:

- **If plan 001 has landed** (`Scribe::AudioDuration` exists): estimate from the
  audio duration, e.g. `minutes = duration_seconds / 60.0`; multiply by a
  conservative per-minute rate. Keep it simple and conservative — the goal is a
  non-zero guard, not exact pricing (settlement happens at `deduct!`).
- **If plan 001 has NOT landed**: you cannot measure duration. Fall back to the
  minimum viable guard: pass a small positive nominal estimate so that any
  account whose `balance <= 0` is rejected. Because `hold!` rejects when
  `balance - estimate < 0`, an estimate of any positive amount rejects a
  zero/negative balance. Document this as the interim behavior.

Do NOT hardcode a large estimate that would reject accounts with legitimate
small balances beyond intent — keep the estimate conservative and comment why.

**Verify**: `ASDF_RUBY_VERSION=3.2.2 bin/rails test test/integration/api/v2/scribe_sessions_test.rb`
→ existing full-lifecycle test still passes (that account has no `AccountCredit`,
so `hold!` returns the unlimited ok token and commit proceeds unchanged).

### Step 2: Floor `deduct!` so it cannot persist a negative balance

In `app/services/metering/quota_guard.rb`, give `deduct!` a non-negative
settlement policy. The chosen floor is **zero** (consistent with the hard-block
decision in Step 0). Options — pick the one the maintainer confirmed:

- Clamp: when a deduction would take `balance_after` below zero, settle only down
  to zero (`balance_after = [balance_before - amount, 0].max`), and record the
  actual settled amount. This never loses the fact that a charge occurred but
  refuses to show a negative ledger.

Keep the change inside `apply_settlement`/`deduct!` only. Preserve:
- the no-`AccountCredit` no-op (`return nil if credit.nil?`),
- the `ActiveRecord::RecordNotUnique` idempotency rescue,
- the row lock inside the transaction.

Do NOT change `refund!`'s direction (it increments).

**Verify**: `ASDF_RUBY_VERSION=3.2.2 bin/rails test test/services/metering/quota_guard_test.rb`
→ existing tests pass (the "deduct decrements the balance" test uses balance 100,
cost 12.5 → 87.5, above the floor, unaffected).

### Step 3: Document the new error code

Add `insufficient_credit` to the inline list/comment of v2 codes near
`render_error` in `app/controllers/api/v2/base_controller.rb` **only if** such a
comment list exists there — if there is no code list to update, skip and instead
add a one-line comment above the new `render_error(code: "insufficient_credit"…)`
call in the controller noting it is a stable public code. Do not restructure the
base controller.

**Verify**: `grep -rn "insufficient_credit" app/controllers/api/v2/` → at least
the controller call is present.

### Step 4: Add tests (see Test plan), then run everything

**Verify**: `ASDF_RUBY_VERSION=3.2.2 bin/rails test` → 0 failures.

## Test plan

**Controller** — add to `test/integration/api/v2/scribe_sessions_test.rb` (model
after the existing "full lifecycle" test at lines 31–64 and reuse its setup):

- **"commit is rejected with 402 when the account has insufficient credit"**:
  create the session through create → audio as the existing lifecycle test does,
  then `create(:account_credit, account: @account, balance: 0)` (the setup
  account `@account` currently has none). Commit and assert:
  - `assert_response :payment_required`
  - `assert_equal "insufficient_credit", JSON.parse(response.body).dig("error", "code")`
  - **no job enqueued and no processing**: the test env uses the `:inline` job
    adapter (`config/environments/test.rb:27`), so if the job did run the session
    would leave `created/uploading`. Assert `session.reload.status` is NOT
    `processing`/`completed` (still `uploading`), and assert
    `UsageEvent.where(scribe_session_id: session.id).count == 0` (no deduction).
- Keep the existing "full lifecycle" test green as the unlimited/no-credit path.

**QuotaGuard** — add to `test/services/metering/quota_guard_test.rb` (model after
"deduct decrements the balance and records a deduction" at lines 44–58):

- **"deduct does not drive the balance below zero"**: `create(:account_credit,
  account: account, balance: 5)`, `create(:usage_event, account: account, cost:
  12.5)`, call `deduct!`, assert `credit.reload.balance.to_f` equals the chosen
  floor (`0.0`), not `-7.5`. Assert a `deduction` `CreditTransaction` still
  exists (the charge is recorded).

Verification: `ASDF_RUBY_VERSION=3.2.2 bin/rails test test/integration/api/v2/scribe_sessions_test.rb test/services/metering/quota_guard_test.rb`
→ all pass, including the new tests.

## Done criteria

Machine-checkable. ALL must hold:

- [ ] `ASDF_RUBY_VERSION=3.2.2 bin/rails test` → 0 failures, including the new 402
      and floor tests
- [ ] `ASDF_RUBY_VERSION=3.2.2 bin/rubocop` → no offenses
- [ ] `grep -n "estimate: 0" app/controllers/api/v2/scribe_sessions_controller.rb` → no matches
- [ ] `grep -rn "insufficient_credit" app/controllers/api/v2/` → present
- [ ] The no-`AccountCredit` unlimited path still passes:
      `ASDF_RUBY_VERSION=3.2.2 bin/rails test test/services/metering/quota_guard_test.rb` → 0 failures
- [ ] No files outside the in-scope list are modified (`git status`)
- [ ] `plans/README.md` status row updated

## STOP conditions

Stop and report back (do not improvise) if:

- The Step 0 decisions (hard-block vs overdraft; reserve vs postpaid) have not
  been confirmed by the maintainer.
- The "Current state" excerpts don't match the live code (drift since `84da325`).
- Enforcing the floor or the estimate appears to require changing
  `orchestrator.rb`, `db/schema.rb`, or the unlimited-no-`AccountCredit` behavior
  (all out of scope) — report instead.
- A verification fails twice after a reasonable fix attempt.
- You cannot determine a safe, conservative estimate (e.g. plan 001 absent AND
  the maintainer has not confirmed the interim zero-balance-reject behavior).

## Maintenance notes

For whoever owns this after it lands:

- This is the **immediate guard**, not full reservation accounting. `hold!` here
  is checked but does not yet decrement `balance` — plan 003 makes holds reserve
  real budget and adds the sweeper. The `deduct!` floor added here must stay
  consistent with 003's reserve-on-hold accounting.
- The commit estimate is deliberately conservative and coarse; final cost is
  settled by `deduct!` after the pipeline runs. If pricing becomes duration-exact
  (plan 001), tighten `commit_estimate`.
- Reviewer should scrutinize: the unlimited path (no `AccountCredit`) still
  proceeds; the `next` vs `return` inside `with_idempotency`; that a rejected
  commit enqueues no job and records no `UsageEvent`; and that `402` uses the new
  stable `insufficient_credit` code.
- Deferred: a DB CHECK constraint on `account_credits.balance >= 0` (belongs with
  plan 003's ledger hardening).
