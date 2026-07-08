# Plan 017: Make GET /api/v2/scribe_sessions O(1) in queries and paginated (kill the outputs N+1)

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan
> in `plans/README.md` — unless a reviewer dispatched you and told you they
> maintain the index.
>
> **Drift check (run first)**:
> `git diff --stat 84da325..HEAD -- app/controllers/api/v2/scribe_sessions_controller.rb app/serializers/scribe_session_serializer.rb test/integration/api/v2/scribe_sessions_test.rb`
> If any in-scope file changed since this plan was written, compare the
> "Current state" excerpts against the live code before proceeding; on a
> mismatch, treat it as a STOP condition.

## Status

- **Priority**: P2
- **Effort**: S
- **Risk**: LOW
- **Depends on**: none
- **Category**: perf
- **Planned at**: commit `84da325`, 2026-07-08

## Why this matters

`GET /api/v2/scribe_sessions` (the account's session-list endpoint) serializes
each session with `ScribeSessionSerializer`, which reads `session.scribe_outputs`.
The controller loads sessions **without** eager-loading that association, so the
serializer fires one extra `SELECT scribe_outputs WHERE scribe_session_id = ?`
**per session** — a classic N+1. The list is also hard-capped at `limit(50)`
with no way to page, so the 51st session onward is simply invisible to clients
and there is no cursor/offset to reach it.

After this plan lands: the endpoint issues a **constant** number of queries
regardless of how many sessions are returned (one for sessions, one preload for
their outputs), and clients can page with `limit`/`offset` params (clamped to a
sane maximum). The per-session JSON shape is unchanged.

## Current state

Files involved and their roles:

- `app/controllers/api/v2/scribe_sessions_controller.rb` — the v2 controller;
  its `index` action and `account_sessions` helper contain the bug.
- `app/serializers/scribe_session_serializer.rb` — plain-Ruby serializer; its
  `as_json` reads `@session.scribe_outputs` (this is what N+1s when the
  association is not preloaded). **Read-only reference — do NOT modify.** Once
  the controller eager-loads `:scribe_outputs`, `.map` on the loaded association
  iterates in memory with no extra query, so no serializer change is needed.
- `test/integration/api/v2/scribe_sessions_test.rb` — the existing integration
  test for this endpoint; you will extend it.

The N+1 + hardcoded cap, `app/controllers/api/v2/scribe_sessions_controller.rb:73-77`:

```ruby
# GET /api/v2/scribe_sessions
def index
  sessions = account_sessions.order(created_at: :desc).limit(50)
  render json: { scribe_sessions: sessions.map { |s| serialize(s) } }, status: :ok
end
```

The account-scoped relation, `scribe_sessions_controller.rb:81-86`:

```ruby
# Account-scoped session relation. Scopes through belongs_to :account
# rather than a has_many on Account so this chunk does not depend on a
# model it cannot edit; a cross-account :id therefore 404s.
def account_sessions
  ScribeSession.where(account: current_account)
end
```

`serialize`, `scribe_sessions_controller.rb:156-158`:

```ruby
def serialize(session)
  ScribeSessionSerializer.new(session).as_json
end
```

The association read that N+1s, `app/serializers/scribe_session_serializer.rb:9-18`:

```ruby
def as_json(*)
  {
    id: @session.id,
    status: @session.status,
    mode: @session.mode,
    language: @session.language,
    expires_at: @session.expires_at,
    outputs: @session.scribe_outputs.map { |output| serialize_output(output) }
  }
end
```

The association exists on the model, `app/models/scribe_session.rb:6`:

```ruby
has_many :scribe_outputs, dependent: :destroy
```

**Convention:** v2 controllers use plain-Ruby serializers under
`app/serializers` (this endpoint already does). The stable v2 error envelope and
auth live in `app/controllers/api/v2/base_controller.rb`; `index` does not need
error handling changes. Response body stays `{ scribe_sessions: [...] }` — do not
add new top-level keys (existing clients and the existing test depend on the
shape).

## Commands you will need

| Purpose | Command | Expected on success |
|---|---|---|
| Prepare test DB | `ASDF_RUBY_VERSION=3.2.2 bin/rails db:test:prepare` | exit 0 |
| Single test file | `ASDF_RUBY_VERSION=3.2.2 bin/rails test test/integration/api/v2/scribe_sessions_test.rb` | 0 failures, 0 errors |
| Tests (all) | `ASDF_RUBY_VERSION=3.2.2 bin/rails test` | 0 failures |
| Lint | `ASDF_RUBY_VERSION=3.2.2 bin/rubocop` | no offenses |

(The `ASDF_RUBY_VERSION=3.2.2` prefix is required on this machine so asdf
resolves Ruby 3.2.2; without it `bin/rails` may not run.)

## Scope

**In scope** (the only files you should modify or create):
- `app/controllers/api/v2/scribe_sessions_controller.rb` (modify)
- `test/integration/api/v2/scribe_sessions_test.rb` (extend)

**Out of scope** (do NOT touch, even though they look related):
- `app/serializers/scribe_session_serializer.rb` — it already works correctly
  once the controller preloads `:scribe_outputs`. Modifying it is unnecessary and
  risks changing the response shape.
- `app/models/scribe_session.rb` — the `has_many :scribe_outputs` is already
  correct; no model change is needed.
- The response envelope shape — keep it exactly `{ scribe_sessions: [...] }`.
  Do NOT add pagination metadata keys; clients and the existing
  `"index lists account-scoped sessions"` test depend on the current shape.

## Git workflow

- Branch: `advisor/017-fix-v2-sessions-list-n1`
- Commit per logical unit; message style matches the repo log (short imperative,
  e.g. `git log` shows "Add …", "Fix …"). Suggested: `Fix v2 sessions list N+1 and add pagination`.
- Do NOT push or open a PR unless the operator instructed it.

## Steps

### Step 1: Eager-load outputs and drive limit/offset from params

Edit `app/controllers/api/v2/scribe_sessions_controller.rb`.

Add two constants at the top of the class body (just under
`OUTPUT_TYPES = %w[transcript form note].freeze` at line 6):

```ruby
DEFAULT_PAGE_LIMIT = 50
MAX_PAGE_LIMIT = 100
```

Replace the `index` action (lines 73-77) with:

```ruby
# GET /api/v2/scribe_sessions
def index
  sessions = account_sessions
             .includes(:scribe_outputs)
             .order(created_at: :desc)
             .limit(page_limit)
             .offset(page_offset)
  render json: { scribe_sessions: sessions.map { |s| serialize(s) } }, status: :ok
end
```

Add two private helpers (put them in the `private` section, e.g. right after the
`account_sessions` method around line 86):

```ruby
# Requested page size, clamped to [1, MAX_PAGE_LIMIT]; defaults to
# DEFAULT_PAGE_LIMIT when absent or non-positive.
def page_limit
  requested = params[:limit].presence&.to_i
  return DEFAULT_PAGE_LIMIT unless requested&.positive?

  [ requested, MAX_PAGE_LIMIT ].min
end

# Requested offset, floored at 0.
def page_offset
  offset = params[:offset].presence&.to_i
  offset&.positive? ? offset : 0
end
```

Do NOT change `account_sessions`, `serialize`, or the serializer. The only
behavioral change is: outputs are preloaded, and `limit`/`offset` come from
params instead of the hardcoded `50`.

**Verify**: `ASDF_RUBY_VERSION=3.2.2 bin/rails test test/integration/api/v2/scribe_sessions_test.rb`
→ the pre-existing tests still pass (0 failures). In particular
`"index lists account-scoped sessions"` must stay green (default limit 50 still
returns the account's one session).

### Step 2: Add the N+1, pagination, and cap tests

See the Test plan below, then run the file.

**Verify**: `ASDF_RUBY_VERSION=3.2.2 bin/rails test test/integration/api/v2/scribe_sessions_test.rb`
→ 0 failures, including the new tests.

## Test plan

Extend `test/integration/api/v2/scribe_sessions_test.rb`. The file already has a
`setup` block that creates `@account`, `@user`, `@token`, and `@headers`, and an
`"index lists account-scoped sessions"` test at lines 147-157 — model the new
tests after it. The suite has **no** existing query-count helper, so add one as a
private method in this test class (place it in the `private` section near
`audio_upload`):

```ruby
# Counts real ActiveRecord SELECT/INSERT/UPDATE/DELETE queries issued inside the
# block, ignoring schema reflection, cache hits, and transaction control
# statements. Used to prove the list endpoint does not N+1.
def count_ar_queries
  count = 0
  callback = lambda do |_name, _start, _finish, _id, payload|
    next if payload[:cached]
    next if payload[:name] == "SCHEMA"
    next if payload[:sql].to_s =~ /\A\s*(BEGIN|COMMIT|ROLLBACK|SAVEPOINT|RELEASE|SET|SHOW)\b/i

    count += 1
  end
  ActiveSupport::Notifications.subscribed(callback, "sql.active_record") { yield }
  count
end
```

Add three tests:

1. **"index does not run an extra query per session (no N+1 on outputs)"** —
   the core regression test. Compare the query count for 1 session vs several;
   equality proves the count is independent of the number of sessions.

   ```ruby
   test "index does not run an extra query per session (no N+1 on outputs)" do
     s1 = create(:scribe_session, account: @account, api_token: @token, user: @user)
     create(:scribe_output, scribe_session: s1)

     q1 = count_ar_queries { get "/api/v2/scribe_sessions", headers: @headers }
     assert_response :ok
     body = JSON.parse(response.body)
     assert body["scribe_sessions"].all? { |s| s.key?("outputs") }, "output shape changed"

     3.times do
       s = create(:scribe_session, account: @account, api_token: @token, user: @user)
       create(:scribe_output, scribe_session: s)
     end

     q2 = count_ar_queries { get "/api/v2/scribe_sessions", headers: @headers }
     assert_response :ok

     assert_equal q1, q2,
       "query count grew with more sessions -> N+1 not fixed (got #{q1} then #{q2})"
   end
   ```

   On the current (unfixed) code this fails: the serializer reads
   `session.scribe_outputs` per session, so `q2 > q1`. After Step 1 both counts
   are equal (one sessions query + one outputs preload, regardless of N).

2. **"index respects limit and offset params"**:

   ```ruby
   test "index respects limit and offset params" do
     3.times { create(:scribe_session, account: @account, api_token: @token, user: @user) }

     get "/api/v2/scribe_sessions", params: { limit: 2 }, headers: @headers
     assert_response :ok
     assert_equal 2, JSON.parse(response.body)["scribe_sessions"].size

     get "/api/v2/scribe_sessions", params: { limit: 2, offset: 2 }, headers: @headers
     assert_response :ok
     assert_equal 1, JSON.parse(response.body)["scribe_sessions"].size
   end
   ```

3. **"index caps the page size at the maximum"** — seed just over the cap with a
   single bulk insert (fast; `insert_all` auto-fills timestamps in Rails 8, and
   `status` has a DB default). NULL `api_token_id`/`idempotency_key` are fine —
   Postgres treats NULLs as distinct under the unique index, so no conflict.

   ```ruby
   test "index caps the page size at the maximum" do
     now = Time.current
     rows = Array.new(105) { { account_id: @account.id, status: "created", created_at: now, updated_at: now } }
     ScribeSession.insert_all(rows)

     get "/api/v2/scribe_sessions", params: { limit: 9999 }, headers: @headers
     assert_response :ok
     assert_equal 100, JSON.parse(response.body)["scribe_sessions"].size
   end
   ```

Verification: `ASDF_RUBY_VERSION=3.2.2 bin/rails test test/integration/api/v2/scribe_sessions_test.rb`
→ all pass, including the 3 new tests.

## Done criteria

Machine-checkable. ALL must hold:

- [ ] `ASDF_RUBY_VERSION=3.2.2 bin/rails test test/integration/api/v2/scribe_sessions_test.rb` → 0 failures, 0 errors, includes the 3 new tests
- [ ] `ASDF_RUBY_VERSION=3.2.2 bin/rails test` → 0 failures
- [ ] `ASDF_RUBY_VERSION=3.2.2 bin/rubocop` → no offenses
- [ ] `grep -n "includes(:scribe_outputs)" app/controllers/api/v2/scribe_sessions_controller.rb` → 1 match
- [ ] `grep -n "limit(50)" app/controllers/api/v2/scribe_sessions_controller.rb` → no matches
- [ ] `git diff --name-only` shows ONLY `app/controllers/api/v2/scribe_sessions_controller.rb` and `test/integration/api/v2/scribe_sessions_test.rb` (plus `plans/README.md`)
- [ ] `plans/README.md` status row updated

## STOP conditions

Stop and report back (do not improvise) if:

- The "Current state" excerpts don't match the live code (the files drifted
  since commit `84da325`) — especially if `ScribeSessionSerializer` no longer
  reads `@session.scribe_outputs`, or if `index` already differs from lines 73-77.
- The no-N+1 test still shows `q2 > q1` after Step 1 (preloading did not take
  effect) — investigate whether the serializer is calling something other than
  the preloaded `scribe_outputs` association before improvising.
- Making the tests pass appears to require editing the serializer or the model
  (it must not — the fix is entirely in the controller).
- Any verification fails twice after a reasonable fix attempt.

## Maintenance notes

For whoever owns this after it lands:

- The response shape was deliberately kept as `{ scribe_sessions: [...] }` with
  no pagination metadata. If clients later need total counts or `next`/`prev`
  cursors, add a `meta` key in a follow-up — but that is an API-shape change and
  should be versioned/communicated, not slipped in here.
- `MAX_PAGE_LIMIT = 100` is a safety clamp, not a product decision. Revisit if a
  legitimate client needs larger pages.
- The N+1 regression test asserts *equality of query counts across N*, not an
  absolute number, so it is robust to unrelated per-request query changes (auth,
  etc.). If someone reintroduces a per-session association read in the serializer
  (e.g. `session.transcript`), this test will catch it only if that association
  is also unpreloaded — reviewer should ensure any new serialized association is
  added to the `includes(...)` in `index`.
- Reviewer should scrutinize: `page_limit`/`page_offset` clamping (no negative
  offset, no zero/negative limit, cap enforced) and that `order(created_at: :desc)`
  is still applied after `includes`.
