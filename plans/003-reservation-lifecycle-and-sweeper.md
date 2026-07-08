# Plan 003: Complete (or remove) the reservation lifecycle — holds, sweeper, and refunds

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan
> in `plans/README.md` — unless a reviewer dispatched you and told you they
> maintain the index.
>
> **Drift check (run first)**:
> `git diff --stat 84da325..HEAD -- app/services/metering/quota_guard.rb app/jobs/process_scribe_session_job.rb app/services/scribe/orchestrator.rb config/recurring.yml`
> If any in-scope file changed since this plan was written, compare the
> "Current state" excerpts against the live code before proceeding; on a
> mismatch, treat it as a STOP condition.

## Status

- **Priority**: P2
- **Effort**: L
- **Risk**: MED
- **Depends on**: plans/002-enforce-quota-at-commit.md
- **Category**: bug
- **Planned at**: commit `84da325`, 2026-07-08

## Why this matters

The reservation lifecycle is **half-built**: comments across the codebase claim a
"reservation sweeper trues up the ledger for stuck holds," but no sweeper exists,
`config/recurring.yml` is entirely commented out, `hold!` creates a hold
transaction that never decrements `credit.balance` (so a hold reserves nothing),
`refund!` is defined but called from nowhere in `app/`, and the
`usage_events.reserved_until` column, the `(status, reserved_until)` index, and
the `pending` status are unused scaffolding. This means concurrent commits can
oversell (holds don't reserve budget) and dangling holds are never released.
After this plan, EITHER the reservation lifecycle is real (holds reserve budget,
a recurring sweeper releases stale holds, per-event failures refund) OR the dead
scaffolding and misleading comments are removed — decided by the maintainer.

## Current state

Files involved and their roles:

- `app/services/metering/quota_guard.rb` — `hold!`, `deduct!`, `refund!`.
- `app/jobs/process_scribe_session_job.rb` — async pipeline runner; comment
  claims the sweeper trues up the ledger; marks `failed` without re-raising.
- `app/services/scribe/orchestrator.rb` — same "sweeper trues up" claim in the
  metering comment; per-output metering is best-effort.
- `config/recurring.yml` — Solid Queue recurring-task config; entirely commented.
- `db/schema.rb` — `usage_events` has the unused `reserved_until` column and
  `(status, reserved_until)` index; `pending` status.

`hold!` creates a hold whose `balance_before == balance_after` and never
decrements the credit, `app/services/metering/quota_guard.rb:31-45`:

```ruby
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
    balance_after: credit.balance   # <- no decrement; nothing reserved
  )
  Token.new(ok: true, transaction: txn, unlimited: false)
end
```

`refund!` exists but is called nowhere in `app/`,
`app/services/metering/quota_guard.rb:53-56` (grep-confirmed: `grep -rn
"refund!" app/` returns only this definition and the class docstring):

```ruby
def refund!(usage_event)
  amount = usage_event.cost.to_d
  apply_settlement(usage_event, :refund, amount, sign: 1)
end
```

The "sweeper trues up" claims with no sweeper behind them —
`app/jobs/process_scribe_session_job.rb:1-31`:

```ruby
# Any unexpected error marks the session :failed with a sanitized message and is
# logged but NOT re-raised, so a poison job does not retry forever (the
# reservation sweeper trues up the ledger for stuck holds).
class ProcessScribeSessionJob < ApplicationJob
  def perform(scribe_session_id)
    ...
  rescue StandardError => e
    session&.update(status: :failed, error: { message: e.message })
    ...
```

`app/services/scribe/orchestrator.rb:213-224`:

```ruby
# Records + deducts a usage_event for one physical attempt, best-effort.
# Errors are logged but never propagate (the reservation sweeper trues up the
# ledger for any hold left dangling by a metering failure).
def meter(function:, stage:, scribe_output: nil)
  ...
```

`config/recurring.yml` is entirely commented out (verified — the whole file):

```yaml
# production:
#   periodic_cleanup:
#     class: CleanSoftDeletedRecordsJob
#     ...
```

Unused scaffolding in `db/schema.rb` (verified) — `usage_events` (lines
280–314): `t.string "status", default: "pending"` (302), `t.datetime
"reserved_until"` (304), and `index ["status", "reserved_until"]` (313). The
`UsageEvent` model enum is `pending/finalized/failed`
(`app/models/usage_event.rb:6`), but `UsageRecorder.record` always writes
`status: :finalized` and never sets `reserved_until` — so `pending` and
`reserved_until` are dead.

**Infra facts (verified during recon):**
- Solid Queue is the prod adapter (`config/environments/production.rb:53`:
  `config.active_job.queue_adapter = :solid_queue`) and reads `config/recurring.yml`
  for recurring tasks. Test env uses `:inline` (`config/environments/test.rb:27`).
- Solid Queue is present: `Gemfile:54` `gem "solid_queue", "~> 1.1.0"`.
- The unique idempotency index on settlements is `(usage_event_id, txn_type)`
  (`db/schema.rb:130`) — `deduct!`/`refund!` rely on it.

## Commands you will need

| Purpose | Command | Expected on success |
|---|---|---|
| Prepare test DB | `ASDF_RUBY_VERSION=3.2.2 bin/rails db:test:prepare` | exit 0 |
| Migrate (if you add one) | `ASDF_RUBY_VERSION=3.2.2 bin/rails db:migrate` | exit 0 |
| QuotaGuard test | `ASDF_RUBY_VERSION=3.2.2 bin/rails test test/services/metering/quota_guard_test.rb` | 0 failures |
| Sweeper test | `ASDF_RUBY_VERSION=3.2.2 bin/rails test test/services/metering/reservation_sweeper_test.rb` | 0 failures |
| Tests (all) | `ASDF_RUBY_VERSION=3.2.2 bin/rails test` | 0 failures |
| Lint | `ASDF_RUBY_VERSION=3.2.2 bin/rubocop` | no offenses |

(The `ASDF_RUBY_VERSION=3.2.2` prefix is required so asdf resolves Ruby 3.2.2.)

## Scope

### Branch A — implement reservations (if maintainer chooses reserve-on-hold)

**In scope**:
- `app/services/metering/quota_guard.rb` (reserve-on-hold + settle/release)
- `app/services/metering/reservation_sweeper.rb` (create)
- `config/recurring.yml` (author the sweeper schedule)
- `app/services/scribe/orchestrator.rb` (wire `refund!` for per-event failures)
- `test/services/metering/quota_guard_test.rb` (extend)
- `test/services/metering/reservation_sweeper_test.rb` (create)
- A migration ONLY if you must add a `credit_transactions` link (`hold` →
  settlement) — avoid if the existing columns suffice.

### Branch B — remove the dead scaffolding (if maintainer chooses postpaid)

**In scope**:
- `app/jobs/process_scribe_session_job.rb` (fix the misleading comment)
- `app/services/scribe/orchestrator.rb` (fix the misleading comment)
- `app/services/metering/quota_guard.rb` (remove `refund!` if truly unused, or
  document it as intentionally-reserved API)
- A migration to drop `usage_events.reserved_until` + its index and the `pending`
  status default if the maintainer confirms they are truly dead.

**Out of scope for BOTH branches**:
- The commit-time gate itself (plan 002 owns it).
- The unlimited-no-`AccountCredit` behavior (must remain intact).
- Metering-is-best-effort structure in the orchestrator (a metering error must
  never demote a finalized output or fail the session — see the regression tests
  in `test/services/scribe/orchestrator_test.rb:225-257`). Preserve it.
- `ProcessScribeSessionJob` marking `failed` without re-raising — preserve it.

## Git workflow

- Branch: `advisor/003-reservation-lifecycle-and-sweeper`
- Commit per stage (a/b/c below) or per logical unit; short imperative messages
  matching the repo log (e.g. `Reserve credit on hold`, `Add reservation sweeper`,
  `Remove dead reservation scaffolding`).
- Do NOT push or open a PR unless the operator instructed it.

## Steps

### Step 0 (DECISION STOP — reserve-on-hold vs. postpaid — decide FIRST)

This choice must be consistent with plan 002. Present both to the maintainer and
STOP until answered:

- **Reserve-on-hold (Branch A):** `hold!` decrements `credit.balance` by the
  estimate; finalize settles the difference; the sweeper releases stale holds.
  Prevents oversell under concurrency. More code, needs the sweeper wired.
- **Postpaid (Branch B):** keep charging only at `deduct!` (plan 002's floor is
  the guard); DELETE the misleading "sweeper trues up" comments and the dead
  `reserved_until`/`pending` scaffolding so the code stops lying.

Do not implement both. Record the decision in the PR description.

---

### Branch A steps (reserve-on-hold)

Stage the work so the tree is never broken between commits:

#### A(a): Add the reservation sweeper for dangling holds

Create `app/services/metering/reservation_sweeper.rb`. It finds holds/`pending`
usage_events whose `reserved_until` has passed and releases them: transition the
event to `failed` (or release the hold transaction) and return the reserved
budget to `credit.balance` via a `release` settlement. Keep all balance
mutations inside a locked `AccountCredit.transaction` exactly like
`apply_settlement` (`quota_guard.rb:63-85`). It must be idempotent (a
double-sweep must not double-release — reuse the unique `(usage_event_id,
txn_type)` index by using a distinct `txn_type` such as `release`).

Wire it as a Solid Queue recurring task by authoring `config/recurring.yml`
(currently all commented). Add a `production:` block scheduling the sweeper, e.g.:

```yaml
production:
  reservation_sweeper:
    class: Metering::ReservationSweeperJob
    queue: background
    schedule: every 5 minutes
```

If you schedule via a job class, create a thin `Metering::ReservationSweeperJob`
that calls `Metering::ReservationSweeper`. (Solid Queue recurring entries invoke
either a `class` job or a `command`.) Keep the schedule conservative.

**Verify**: `ASDF_RUBY_VERSION=3.2.2 bin/rails test test/services/metering/reservation_sweeper_test.rb`
→ the orphaned-hold release test passes (see Test plan).

#### A(b): Make `hold!` reserve real budget

In `quota_guard.rb`, change `hold!` so the hold decrements `credit.balance` by
the estimate and sets `balance_after = balance_before - estimate` (and set
`reserved_until` on the associated usage_event if you model holds as events).
Finalize (`deduct!`) must then settle against the reservation rather than
double-charging — reconcile the hold's reserved amount with the actual cost
(release the excess, or charge the shortfall). Keep the unlimited-no-credit
no-op and the row lock. This is the delicate part — keep `deduct!`'s existing
idempotency (unique index) intact.

**Verify**: `ASDF_RUBY_VERSION=3.2.2 bin/rails test test/services/metering/quota_guard_test.rb`
→ the new "hold reserves balance" and oversell tests pass; existing deduct/refund
tests still pass.

#### A(c): Wire `refund!` for per-event failures

In `app/services/scribe/orchestrator.rb`, call `Metering::QuotaGuard.refund!`
ONLY for an event whose own physical call failed — never for a successful
sibling. Design carefully: the orchestrator already isolates per-output failures
(`process_output` rescue, `orchestrator.rb:133-138`) and meters best-effort
OUTSIDE that rescue (`orchestrator.rb:40-45`). Refund must respect the same
boundary: a metering/refund error must NOT demote a finalized output or fail the
session (see the regression tests at `orchestrator_test.rb:225-257`). Prefer
refunding via the sweeper/settlement path so a refund failure is swallowed like
other best-effort metering.

**Verify**: `ASDF_RUBY_VERSION=3.2.2 bin/rails test test/services/scribe/orchestrator_test.rb`
→ all existing regression tests still pass (metering failure does not demote a
success; partial/failed rollups unchanged).

---

### Branch B steps (postpaid — remove the scaffolding)

#### B(a): Fix the misleading comments

- `app/jobs/process_scribe_session_job.rb:12-14` — remove the "(the reservation
  sweeper trues up the ledger for stuck holds)" clause; replace with the truth:
  the job marks `failed` without re-raising so a poison job does not retry
  forever. Keep the behavior.
- `app/services/scribe/orchestrator.rb:213-215` — remove "(the reservation
  sweeper trues up the ledger for any hold left dangling by a metering
  failure)"; state that metering is best-effort and a failure is logged and
  swallowed.

#### B(b): Drop the dead scaffolding (only with maintainer confirmation)

Generate a migration to remove `usage_events.reserved_until` and its
`(status, reserved_until)` index, and drop the `pending` default on `status`
(the enum keeps `finalized`/`failed`). If `refund!` is confirmed unused and not
part of a public/reserved API, remove it and the `refund` branch; otherwise leave
it with a comment "reserved for future refund flows; intentionally unused."

**Verify**:
- `ASDF_RUBY_VERSION=3.2.2 bin/rails db:migrate` → exit 0, and
  `ASDF_RUBY_VERSION=3.2.2 bin/rails db:test:prepare` → exit 0.
- `grep -rn "reservation sweeper" app/` → no matches.
- `ASDF_RUBY_VERSION=3.2.2 bin/rails test` → 0 failures.

## Test plan

Model new tests after the existing `test/services/metering/quota_guard_test.rb`
(it uses `create(:account)`, `create(:account_credit, …)`, `create(:usage_event,
…)` and asserts on `CreditTransaction`).

**Branch A:**
- In `quota_guard_test.rb`:
  - **"hold reserves balance"**: `create(:account_credit, balance: 100)`, `hold!`
    with `estimate: 10`, assert `credit.reload.balance.to_f == 90.0` and a `hold`
    `CreditTransaction` with `balance_after == 90`.
  - **"concurrent/serialized holds cannot oversell"**: with `balance: 15`, two
    sequential `hold!(estimate: 10)` — the first reserves (balance 5), the second
    returns `ok? == false` (5 - 10 < 0). Assert only one hold transaction and
    balance never negative.
- Create `test/services/metering/reservation_sweeper_test.rb`:
  - **"sweeper releases an orphaned hold past reserved_until"**: set up a hold /
    `pending` usage_event with `reserved_until` in the past and a decremented
    balance; run the sweeper; assert the budget is returned to `credit.balance`
    and the event is `failed`/released; running the sweeper twice does not
    double-release (idempotent via the unique `(usage_event_id, txn_type)` index).

**Branch B:**
- No new behavior tests; rely on the full suite staying green after removals.
  Add a guard test only if you delete `refund!` — assert the class still loads
  and `deduct!`/`hold!` behave as before.

Verification: `ASDF_RUBY_VERSION=3.2.2 bin/rails test test/services/metering/`
→ all pass, including the new tests (Branch A).

## Done criteria

Machine-checkable. ALL must hold (for the chosen branch):

**Branch A:**
- [ ] `app/services/metering/reservation_sweeper.rb` exists and is scheduled in
      `config/recurring.yml` (`grep -n "reservation_sweeper" config/recurring.yml`)
- [ ] `ASDF_RUBY_VERSION=3.2.2 bin/rails test test/services/metering/` → 0 failures,
      includes "hold reserves balance", oversell, and sweeper release tests
- [ ] `ASDF_RUBY_VERSION=3.2.2 bin/rails test test/services/scribe/orchestrator_test.rb` → 0 failures (regressions intact)

**Branch B:**
- [ ] `grep -rn "reservation sweeper" app/` → no matches
- [ ] If scaffolding dropped: `ASDF_RUBY_VERSION=3.2.2 bin/rails db:migrate` → exit 0

**Both:**
- [ ] `ASDF_RUBY_VERSION=3.2.2 bin/rails test` → 0 failures
- [ ] `ASDF_RUBY_VERSION=3.2.2 bin/rubocop` → no offenses
- [ ] The unlimited-no-`AccountCredit` no-op still holds (quota_guard_test green)
- [ ] No files outside the in-scope list are modified (`git status`)
- [ ] `plans/README.md` status row updated

## STOP conditions

Stop and report back (do not improvise) if:

- Step 0 (reserve vs postpaid) has not been decided by the maintainer, or the
  decision is inconsistent with what plan 002 implemented.
- The "Current state" excerpts don't match live code (drift since `84da325`).
- Branch A: making `hold!` reserve budget breaks the existing deduct idempotency
  or the unlimited-no-credit path, and the fix isn't obvious after one attempt.
- Any change would demote a finalized output or fail a session on a metering
  error (the by-design boundary) — the orchestrator regression tests must stay
  green; if they can't, STOP.
- A migration is required but dropping columns is not confirmed safe by the
  maintainer (Branch B).
- A verification fails twice after a reasonable fix attempt.

## Maintenance notes

For whoever owns this after it lands:

- Branch A introduces a recurring job — verify Solid Queue's recurring scheduler
  is actually running in prod (a scheduled task that no worker picks up is as
  dead as no task). Confirm the `queue` name in `recurring.yml` matches a worked
  queue in `config/queue.yml` (workers listen on `"*"`).
- Reserve-on-hold changes the meaning of `credit.balance` (now net of open
  holds). Any dashboard/report reading `balance` must account for reserved funds.
- Reviewer should scrutinize: refund only ever applies to the failed event, never
  a successful sibling; the sweeper is idempotent; and the metering best-effort
  boundary (`orchestrator_test.rb:225-257`) is preserved.
- Deferred: a DB CHECK constraint on `account_credits.balance >= 0` pairs well
  with reserve-on-hold accounting (mentioned as deferred in plan 002).
