# Plan 005: Drop the plaintext `token` column and make API tokens truly reveal-once

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan
> in `plans/README.md` — unless a reviewer dispatched you and told you they
> maintain the index.
>
> **Drift check (run first)**:
> `git diff --stat 84da325..HEAD -- app/models/api_token.rb app/controllers/api_tokens_controller.rb app/views/api_tokens/index.html.erb app/views/api_tokens/show.html.erb db/schema.rb test/models/api_token_test.rb`
> If any in-scope file changed since this plan was written, compare the
> "Current state" excerpts against the live code before proceeding; on a
> mismatch, treat it as a STOP condition.

## Status

- **Priority**: P1
- **Effort**: M
- **Risk**: MED
- **Depends on**: none
- **Category**: security
- **Planned at**: commit `84da325`, 2026-07-08

## Why this matters

API bearer tokens (finding F4) are stored in cleartext at rest: the model
dual-writes the raw secret to a plaintext `token` column that is `NOT NULL` and
carries a unique index, and the web UI prints that plaintext value on the token
list and detail pages forever. Authentication already resolves tokens purely by
SHA-256 digest (`ApiToken.authenticate` → `token_digest`), so the plaintext
column is dead weight that only increases blast radius: a leaked DB dump or an
over-broad admin view hands out live credentials. This plan removes the
plaintext column and its index, keeps the digest as the sole persisted secret,
and turns the UI into a true reveal-once flow (full token shown once at
creation, `token_prefix` everywhere after).

## Current state

- `app/models/api_token.rb` — the model. Auth is digest-only; the plaintext
  column is a transitional dual-write.

  `app/models/api_token.rb:9-13` (reveal-once reader + the plaintext validation
  to remove):
  ```ruby
  # The plaintext token is available only on the instance that created it
  # (reveal-once). Persisted state is the digest.
  attr_reader :raw_token

  validates :token, presence: true, uniqueness: true
  validates :token_digest, presence: true, uniqueness: true
  ```

  `app/models/api_token.rb:25-29` (auth uses `token_digest` ONLY — this is why
  the plaintext column is safe to drop):
  ```ruby
  def self.authenticate(raw)
    return nil if raw.to_s.strip.empty?

    active.find_by(token_digest: digest_for(raw))
  end
  ```

  `app/models/api_token.rb:41-51` (the dual-write to remove is the `self.token =
  raw` line):
  ```ruby
  def generate_token
    return if token_digest.present?

    raw = "#{TOKEN_PREFIX}#{SecureRandom.hex(20)}"
    @raw_token = raw
    # Transitional dual-write: the legacy `token` column is NOT NULL until the
    # plaintext column is dropped. Auth uses token_digest only.
    self.token = raw
    self.token_digest = self.class.digest_for(raw)
    self.token_prefix = raw[0, 12]
  end
  ```

- `db/schema.rb` — the `api_tokens` table today has BOTH a plaintext `token`
  (`NOT NULL`, unique index) and the `token_digest` (unique index):
  ```ruby
  create_table "api_tokens", force: :cascade do |t|
    t.string "name"
    t.bigint "user_id", null: false
    t.string "token", null: false
    ...
    t.string "token_digest"
    t.string "token_prefix"
    ...
    t.index ["token"], name: "index_api_tokens_on_token", unique: true
    t.index ["token_digest"], name: "index_api_tokens_on_token_digest", unique: true
  end
  ```

- `app/controllers/api_tokens_controller.rb:16-23` (`create` redirects and does
  NOT surface `raw_token` — so today the show page can only ever print the
  persisted plaintext `token`; that is the whole reveal-once gap):
  ```ruby
  def create
    @api_token = current_user.api_tokens.new(api_token_params)
    if @api_token.save
      redirect_to @api_token, notice: "API token was successfully created."
    else
      render :new, status: :unprocessable_entity
    end
  end
  ```
  `set_api_token` (`:32-34`) reloads the record via `find`, so `@api_token.raw_token`
  is `nil` in the `show` action — the raw value must be carried across the
  redirect via `flash`.

- `app/views/api_tokens/index.html.erb:18` renders the persisted plaintext token
  for EVERY token, forever:
  ```erb
  <td class="px-6 py-4 whitespace-nowrap text-sm font-medium text-gray-900"><%= token.token %></td>
  ```

- `app/views/api_tokens/show.html.erb:13-16` also renders the persisted plaintext
  token:
  ```erb
  <div class="bg-white px-4 py-5 sm:grid sm:grid-cols-3 sm:gap-4 sm:px-6">
    <dt class="text-sm font-medium text-gray-500">Token</dt>
    <dd class="mt-1 text-sm text-gray-900 sm:mt-0 sm:col-span-2"><%= @api_token.token %></dd>
  </div>
  ```

- Confirmed readers of the plaintext `.token` attribute (recon `grep`): ONLY the
  two views above. There is no `ApiToken` Administrate dashboard, no serializer,
  and no job/lib reading `api_token.token`. `test/integration/api/v1/transcriptions_golden_test.rb`
  and `test/integration/rate_limit_test.rb` use `@token.raw_token` (in-memory),
  not the column.

- Conventions: migrations are `ActiveRecord::Migration[8.0]`, generated with
  `bin/rails generate migration`. Rails' encrypted/signed session cookie backs
  `flash`, so a one-shot secret in `flash` never touches the log or the DB.

## Commands you will need

| Purpose            | Command                                                                              | Expected on success |
|--------------------|--------------------------------------------------------------------------------------|---------------------|
| Generate migration | `ASDF_RUBY_VERSION=3.2.2 bin/rails generate migration <Name>`                         | creates db/migrate file |
| Migrate            | `ASDF_RUBY_VERSION=3.2.2 bin/rails db:migrate`                                        | exit 0; schema.rb updated |
| Prepare test DB    | `ASDF_RUBY_VERSION=3.2.2 bin/rails db:test:prepare`                                   | exit 0              |
| Single test        | `ASDF_RUBY_VERSION=3.2.2 bin/rails test test/models/api_token_test.rb`                | all pass            |
| Full tests         | `ASDF_RUBY_VERSION=3.2.2 bin/rails test`                                              | 0 failures          |
| Lint               | `ASDF_RUBY_VERSION=3.2.2 bin/rubocop`                                                 | no offenses         |
| Security scan      | `ASDF_RUBY_VERSION=3.2.2 bin/brakeman --no-pager`                                     | no new warnings     |

## Scope

**In scope** (the only files you should modify):
- `app/models/api_token.rb`
- `app/controllers/api_tokens_controller.rb`
- `app/views/api_tokens/index.html.erb`
- `app/views/api_tokens/show.html.erb`
- `db/migrate/*` (two NEW migration files, created via the generator)
- `db/schema.rb` (regenerated by `db:migrate` — do not hand-edit)
- `test/models/api_token_test.rb`

**Out of scope** (do NOT touch, even though they look related):
- `ApiToken.authenticate` / `digest_for` (`app/models/api_token.rb:25-33`) — auth
  is already digest-only and must stay byte-for-byte identical.
- The `token_digest` / `token_prefix` columns and their validations/indexes.
- Any controller other than `ApiTokensController`.
- Rotating live tokens — that is an operational follow-up (see Maintenance notes),
  not a code change in this plan.

## Git workflow

- Branch: `advisor/005-drop-plaintext-token-column`
- Commit per logical unit (model+views+controller, then each migration), short
  imperative subjects (e.g. `Stop dual-writing plaintext API token`,
  `Drop api_tokens.token plaintext column`).
- Do NOT push or open a PR unless the operator instructed it.

## Steps

Order matters: stop writing the column and make it nullable BEFORE dropping it,
so the running app never inserts `NULL` into a `NOT NULL` column between deploys
(see Maintenance notes for the production two-release rationale).

### Step 1: Stop dual-writing the plaintext token; drop its validation

In `app/models/api_token.rb`:

1. Delete the line `validates :token, presence: true, uniqueness: true` (`:13`).
   Keep `validates :token_digest, presence: true, uniqueness: true`.
2. In `generate_token`, delete the `self.token = raw` line and the two-line
   transitional comment above it (`:46-48`).

Resulting `generate_token`:
```ruby
def generate_token
  return if token_digest.present?

  raw = "#{TOKEN_PREFIX}#{SecureRandom.hex(20)}"
  @raw_token = raw
  self.token_digest = self.class.digest_for(raw)
  self.token_prefix = raw[0, 12]
end
```

**Verify**: `grep -n "self.token = raw\|validates :token," app/models/api_token.rb`
→ no matches.

### Step 2: Make the UI reveal-once (raw token once at creation, prefix elsewhere)

In `app/controllers/api_tokens_controller.rb`, change `create` to stash the raw
token in `flash` before redirecting:
```ruby
def create
  @api_token = current_user.api_tokens.new(api_token_params)
  if @api_token.save
    flash[:raw_token] = @api_token.raw_token
    redirect_to @api_token, notice: "API token created. Copy it now — it will not be shown again."
  else
    render :new, status: :unprocessable_entity
  end
end
```

In `app/views/api_tokens/index.html.erb`, replace the token cell (`:18`) with the
non-secret prefix:
```erb
<td class="px-6 py-4 whitespace-nowrap text-sm font-mono text-gray-900"><%= token.token_prefix %>…</td>
```

In `app/views/api_tokens/show.html.erb`, replace the token row (`:13-16`) so it
shows the full raw token ONLY when it was just created (present in `flash`),
otherwise the prefix:
```erb
<div class="bg-white px-4 py-5 sm:grid sm:grid-cols-3 sm:gap-4 sm:px-6">
  <dt class="text-sm font-medium text-gray-500">Token</dt>
  <dd class="mt-1 text-sm text-gray-900 sm:mt-0 sm:col-span-2">
    <% if flash[:raw_token].present? %>
      <span class="font-mono break-all"><%= flash[:raw_token] %></span>
      <p class="mt-1 text-xs text-red-600">Copy this token now — it will not be shown again.</p>
    <% else %>
      <span class="font-mono"><%= @api_token.token_prefix %>…</span>
    <% end %>
  </dd>
</div>
```

**Verify**: `grep -rn "\.token \|\.token%\|token\.token\|api_token\.token\b" app/views/api_tokens/`
→ no remaining reads of the plaintext `token` attribute (only `token_prefix` /
`raw_token` / `flash[:raw_token]`).

### Step 3: Migration A — make `token` nullable

```
ASDF_RUBY_VERSION=3.2.2 bin/rails generate migration MakeApiTokensTokenNullable
```
Fill the generated file:
```ruby
class MakeApiTokensTokenNullable < ActiveRecord::Migration[8.0]
  def change
    change_column_null :api_tokens, :token, true
  end
end
```

**Verify**: `ASDF_RUBY_VERSION=3.2.2 bin/rails db:migrate` → exit 0. In
`db/schema.rb` the `token` column line no longer has `null: false`.

### Step 4: Migration B — drop the plaintext column and its unique index

```
ASDF_RUBY_VERSION=3.2.2 bin/rails generate migration DropApiTokensTokenColumn
```
Fill the generated file:
```ruby
class DropApiTokensTokenColumn < ActiveRecord::Migration[8.0]
  def change
    remove_index :api_tokens, name: "index_api_tokens_on_token"
    remove_column :api_tokens, :token, :string
  end
end
```

**Verify**: `ASDF_RUBY_VERSION=3.2.2 bin/rails db:migrate` → exit 0. Then
`grep -n '"token"' db/schema.rb` shows no `t.string "token"` and no
`index_api_tokens_on_token` for the `api_tokens` table (only `token_digest` /
`token_prefix` remain).

### Step 5: Update / add model tests

In `test/models/api_token_test.rb`, add a test proving the plaintext column is
gone (keep every existing test — they already cover raw_token exposure, digest,
prefix, and `authenticate`):
```ruby
test "does not persist a plaintext token column" do
  assert_not_includes ApiToken.column_names, "token",
    "the plaintext token column must be dropped; auth uses token_digest only"
end
```

**Verify**: `ASDF_RUBY_VERSION=3.2.2 bin/rails db:test:prepare && ASDF_RUBY_VERSION=3.2.2 bin/rails test test/models/api_token_test.rb`
→ all pass, including the new test and the existing "authenticate resolves an
active token from its raw value".

## Test plan

- New test in `test/models/api_token_test.rb`:
  - "does not persist a plaintext token column" — asserts `ApiToken.column_names`
    excludes `"token"`. This is the exact regression (plaintext-at-rest) the plan
    removes.
- Existing tests that must still pass unchanged (they encode the reveal-once +
  digest contract):
  - "generates raw token, digest, and prefix on create" (`:4-9`) — creation still
    exposes `raw_token`, sets `token_digest` and `token_prefix`.
  - "does not persist the raw token in a queryable form beyond the digest"
    (`:11-15`) — reloaded record has `raw_token == nil`.
  - "authenticate resolves an active token from its raw value" (`:23-26`).
- Structural pattern to follow: the existing tests in this same file
  (`create(:api_token)` + assertions on the returned instance).
- Verification: `ASDF_RUBY_VERSION=3.2.2 bin/rails test` → 0 failures.

## Done criteria

Machine-checkable. ALL must hold:

- [ ] `grep -n "self.token = raw" app/models/api_token.rb` returns no matches
- [ ] `grep -n "validates :token," app/models/api_token.rb` returns no matches
- [ ] `grep -n '"token"' db/schema.rb` shows no `t.string "token"` / `index_api_tokens_on_token` under `api_tokens`
- [ ] `grep -rn "\.token\b" app/views/api_tokens/` returns no read of the plaintext `token` attribute (prefix/raw only)
- [ ] `ASDF_RUBY_VERSION=3.2.2 bin/rails db:migrate` and `db:test:prepare` exit 0
- [ ] `ASDF_RUBY_VERSION=3.2.2 bin/rails test` exits 0; new column-absence test present and passing
- [ ] `ASDF_RUBY_VERSION=3.2.2 bin/rubocop` reports no offenses
- [ ] `ASDF_RUBY_VERSION=3.2.2 bin/brakeman --no-pager` reports no new warnings
- [ ] No files outside the in-scope list are modified (`git status`)
- [ ] `plans/README.md` status row updated

## STOP conditions

Stop and report back (do not improvise) if:

- The code at any "Current state" location does not match the excerpt (drift) —
  especially if `ApiToken.authenticate` no longer looks up by `token_digest`.
- `grep -rn "\.token\b" app lib` (excluding `token_digest`, `token_prefix`,
  `raw_token`, `api_token`, `reset_password_token`) reveals ANY reader of the
  plaintext `token` attribute beyond the two views listed here — an unlisted
  report, serializer, admin dashboard, or external consumer. Do NOT drop the
  column while a consumer still reads it; report the reader instead.
- `db:migrate` fails on Migration B because another object depends on
  `index_api_tokens_on_token` or the column.
- Any existing `api_token_test.rb` test fails after Step 1 for a reason other
  than the intended column removal.

## Maintenance notes

For the human/agent who owns this after the change lands:

- **Production deploy ordering** (zero-downtime): Migration A + the model/view
  changes (which stop writing `token`) should ship in one release; Migration B
  (the drop) should ship in a *later* release, after no running process writes or
  reads `token`. If this repo deploys migrations and code together in a single
  release, that is acceptable here because the model change and both migrations
  land atomically — but keep the two migrations separate so the rollback story
  stays clean.
- **Rotate existing tokens**: this fixes credentials-at-rest going forward, but
  any token minted before this change already had its plaintext persisted (and
  possibly viewed/screenshotted). After the column is dropped, recommend the
  operator revoke-and-reissue existing `ApiToken`s so no historically-exposed
  secret remains valid. This is an operational step, not part of this PR.
- **Reveal-once via `flash`**: the raw token is carried across the create→show
  redirect in the encrypted session cookie and shown exactly once. An alternative
  (if a reviewer objects to a secret transiting the cookie) is to `render :show,
  status: :created` directly from `create` so `@api_token.raw_token` is read from
  the in-memory instance — behaviorally equivalent reveal-once.
- A reviewer should scrutinize: that `authenticate` is untouched, that no view
  or dashboard still prints a full token, and that `token_prefix` is populated
  for display (it is set in `generate_token`).
