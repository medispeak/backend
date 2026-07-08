# Plan 007: Serialize `GET /api/v1/me` through an explicit allowlist

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan
> in `plans/README.md` — unless a reviewer dispatched you and told you they
> maintain the index.
>
> **Drift check (run first)**:
> `git diff --stat 84da325..HEAD -- app/controllers/api/v1/me_controller.rb`
> If any in-scope file changed since this plan was written, compare the
> "Current state" excerpts against the live code before proceeding; on a
> mismatch, treat it as a STOP condition.

## Status

- **Priority**: P1
- **Effort**: S
- **Risk**: LOW
- **Depends on**: none
- **Category**: security
- **Planned at**: commit `84da325`, 2026-07-08

## Why this matters

Finding F6: `GET /api/v1/me` renders the entire `users` row with
`current_user.to_json`. The `users` table includes `encrypted_password`,
`reset_password_token`, `reset_password_sent_at`, `remember_created_at`, and an
`admin` flag — all of which are leaked to any token holder on every call.
`encrypted_password` and `reset_password_token` are credential material (an
offline crack target and a live password-reset primitive), and exposing `admin`
telegraphs privilege. The fix is to return an explicit field allowlist so the
endpoint can never leak a newly-added sensitive column by default.

## Current state

- `app/controllers/api/v1/me_controller.rb:1-10` — dumps the whole row:
  ```ruby
  class Api::V1::MeController < Api::BaseController
    def show
      render json: current_user.to_json
    end

    def destroy
      current_user.destroy
      render json: {}
    end
  end
  ```

- `db/schema.rb` `users` table — the sensitive columns `to_json` currently
  leaks:
  ```ruby
  create_table "users", force: :cascade do |t|
    t.string "email", default: "", null: false
    t.string "encrypted_password", default: "", null: false
    t.string "reset_password_token"
    t.datetime "reset_password_sent_at"
    t.datetime "remember_created_at"
    ...
    t.boolean "admin"
    t.bigint "account_id"
    ...
  end
  ```

- Auth context: `Api::BaseController#authenticate_api_token!` signs the resolved
  user in (`sign_in user, store: false`), so `current_user` is the authenticated
  `User`. A blank/invalid bearer token yields `head :unauthorized`.
- Convention: plain-Ruby serializers live under `app/serializers` (e.g.
  `app/serializers/scribe_session_serializer.rb`). This endpoint is small enough
  that `slice` is sufficient; the serializer is an optional alternative below.
- Route: `resource :me, controller: :me` under `namespace :v1` →
  `GET /api/v1/me`, `DELETE /api/v1/me`.

## Commands you will need

| Purpose      | Command                                                                     | Expected on success |
|--------------|-----------------------------------------------------------------------------|---------------------|
| New test     | `ASDF_RUBY_VERSION=3.2.2 bin/rails test test/integration/api/v1/me_test.rb`  | all pass            |
| Full tests   | `ASDF_RUBY_VERSION=3.2.2 bin/rails test`                                     | 0 failures          |
| Lint         | `ASDF_RUBY_VERSION=3.2.2 bin/rubocop`                                        | no offenses         |
| Security scan| `ASDF_RUBY_VERSION=3.2.2 bin/brakeman --no-pager`                            | no new warnings     |

## Scope

**In scope** (the only files you should modify):
- `app/controllers/api/v1/me_controller.rb`
- `test/integration/api/v1/me_test.rb` (create)

**Out of scope** (do NOT touch, even though they look related):
- `Api::BaseController` and its auth flow.
- The `destroy` action's BEHAVIOR — do NOT change what it does in this plan
  (flag it; see Maintenance notes). You may leave it exactly as-is.
- Any change to the v1 response envelope of other endpoints.

## Git workflow

- Branch: `advisor/007-me-endpoint-serializer`
- One commit; short imperative subject (e.g.
  `Allowlist fields in GET /api/v1/me response`).
- Do NOT push or open a PR unless the operator instructed it.

## Steps

### Step 1: Replace `to_json` with an explicit allowlist

In `app/controllers/api/v1/me_controller.rb`, change `show` to render only
`id`, `email`, and `account_id`:
```ruby
class Api::V1::MeController < Api::BaseController
  def show
    render json: current_user.slice(:id, :email, :account_id)
  end

  def destroy
    current_user.destroy
    render json: {}
  end
end
```
(`User#slice` returns a `Hash` of exactly those attributes; `render json:`
serializes it. Do NOT add `encrypted_password`, `reset_password_token`, or
`admin`.)

**Verify**: `grep -n "to_json" app/controllers/api/v1/me_controller.rb`
→ no matches.

### Step 2: Add a request test locking the allowlist

Create `test/integration/api/v1/me_test.rb`, modeled on the auth/header setup in
`test/integration/api/v1/transcriptions_golden_test.rb` (bearer header from
`create(:api_token).raw_token`):
```ruby
require "test_helper"

class Api::V1::MeTest < ActionDispatch::IntegrationTest
  setup do
    @token = create(:api_token)
    @user = @token.user
    @headers = { "Authorization" => "Bearer #{@token.raw_token}" }
  end

  test "returns exactly the id, email, and account_id allowlist" do
    get "/api/v1/me", headers: @headers

    assert_response :success
    body = JSON.parse(response.body)
    assert_equal %w[account_id email id], body.keys.sort
    assert_equal @user.id, body["id"]
    assert_equal @user.email, body["email"]
    assert_equal @user.account_id, body["account_id"]
  end

  test "never exposes credential or privilege fields" do
    get "/api/v1/me", headers: @headers

    body = JSON.parse(response.body)
    refute body.key?("encrypted_password")
    refute body.key?("reset_password_token")
    refute body.key?("reset_password_sent_at")
    refute body.key?("admin")
  end

  test "unauthenticated request is rejected" do
    get "/api/v1/me"

    assert_response :unauthorized
  end
end
```

**Verify**:
`ASDF_RUBY_VERSION=3.2.2 bin/rails test test/integration/api/v1/me_test.rb`
→ all 3 tests pass.

## Test plan

- New file `test/integration/api/v1/me_test.rb`:
  - "returns exactly the id, email, and account_id allowlist" — asserts the JSON
    keys are exactly `%w[account_id email id]` (fails if any column is added).
  - "never exposes credential or privilege fields" — the exact regression F6:
    `encrypted_password` / `reset_password_token` / `admin` must be absent.
  - "unauthenticated request is rejected" — 401 without a token.
- Structural pattern: `test/integration/api/v1/transcriptions_golden_test.rb`
  (bearer header via `create(:api_token).raw_token`; `JSON.parse(response.body)`).
- Verification: `ASDF_RUBY_VERSION=3.2.2 bin/rails test` → 0 failures.

## Done criteria

Machine-checkable. ALL must hold:

- [ ] `grep -n "to_json" app/controllers/api/v1/me_controller.rb` returns no matches
- [ ] `grep -n "slice(:id, :email, :account_id)" app/controllers/api/v1/me_controller.rb` returns one match
- [ ] `ASDF_RUBY_VERSION=3.2.2 bin/rails test test/integration/api/v1/me_test.rb` passes (3 tests)
- [ ] `ASDF_RUBY_VERSION=3.2.2 bin/rails test` exits 0 with 0 failures
- [ ] `ASDF_RUBY_VERSION=3.2.2 bin/rubocop` reports no offenses
- [ ] `ASDF_RUBY_VERSION=3.2.2 bin/brakeman --no-pager` reports no new warnings
- [ ] No files outside the in-scope list are modified (`git status`)
- [ ] `plans/README.md` status row updated

## STOP conditions

Stop and report back (do not improvise) if:

- `app/controllers/api/v1/me_controller.rb` no longer matches the "Current state"
  excerpt (drift).
- A downstream consumer test breaks because it relied on a field beyond
  `id`/`email`/`account_id` from `/api/v1/me` — report the field rather than
  widening the allowlist to include a sensitive column.
- `current_user` is `nil` in the `show` action during the test (auth wiring
  changed) — the allowlist is correct but the auth path drifted; report it.

## Maintenance notes

For the human/agent who owns this after the change lands:

- If a future client legitimately needs another user field, extend the explicit
  `slice` list — never revert to `to_json`. Consider promoting to a
  `app/serializers/user_serializer.rb` (matching `ScribeSessionSerializer`) once
  more than a couple of fields are needed.
- **Deferred, flag for a product/security decision**: `DELETE /api/v1/me`
  (`destroy`) lets any token holder permanently delete the authenticated user
  (and, via `dependent:` associations, their data). That is a destructive
  capability gated only by a bearer token. Recommend a follow-up to require
  stronger confirmation, soft-delete, or removal of the route — decided
  separately, not in this PR.
- A reviewer should confirm the two allowlist tests fail if `to_json` is
  reintroduced (that is the guard against regressing F6).
