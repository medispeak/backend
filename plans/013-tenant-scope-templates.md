# Plan 013: Stop cross-tenant editing/deletion of Templates, Pages, and FormFields

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan
> in `plans/README.md` — unless a reviewer dispatched you and told you they
> maintain the index.
>
> **Drift check (run first)**:
> `git diff --stat 84da325..HEAD -- app/policies/template_policy.rb app/controllers/templates_controller.rb app/models/template.rb app/models/page.rb config/routes.rb`
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

Any authenticated user can edit or delete **any** tenant's Template (and its
nested Pages/FormFields). The Pundit policy authorizes writes on nothing more
than "a user is signed in," and the policy scope returns every Template in the
database. In a multi-tenant medical app this is a broken-access-control / IDOR
vulnerability: tenant A can destroy tenant B's clinical form templates, which
also silently breaks B's scribe/structuring pipeline (pages drive extraction).
This plan closes the hole. **It begins with a required product decision** —
whether the template library is intentionally shared config or tenant-owned —
because the correct fix differs.

## Current state

- `app/policies/template_policy.rb` — every write is gated only on presence of a
  user, and the scope is unscoped:
  ```ruby
  def create?;  new?;  end          # new? => user.present?
  def update?;  edit?; end          # edit? => user.present?
  def destroy?; user.present?; end

  class Scope < Scope
    def resolve
      Template.all                  # <- every tenant's templates
    end
  end
  ```
  (`create?`/`update?`/`destroy?` at `:14-32`, `Scope#resolve` at `:34-38`.)

- `app/controllers/templates_controller.rb` — authenticated, uses Pundit
  (`authorize`, `policy_scope`, `verify_authorized`). Relevant writes:
  - `set_template` (`:60-65`): `@template = Template.find(params[:id])` then
    `authorize @template` — the `find` is global, so authorization is the only
    tenant guard, and today it always passes.
  - `destroy` (`:53-56`): `@template.destroy`.
  - `update` (`:43-50`): `@template.update(template_params)`.
  - `create` (`:26-36`): `@template = Template.new(template_params)` — note it
    does **not** set an owning account today.

- `app/models/template.rb` — has NO `account_id` / owner association:
  ```ruby
  class Template < ApplicationRecord
    has_many :domains, dependent: :destroy
    has_many :pages, dependent: :destroy
    ...
  end
  ```
  `db/schema.rb` `create_table "templates"` columns are: `name`, `description`,
  `archived`, timestamps — **no** `account_id`.

- `app/models/page.rb` — `belongs_to :template`, has `form_fields`; also NO
  `account_id`. FormFields/Pages inherit ownership transitively from Template.

- `config/routes.rb:29-39` — the user-facing (non-admin) write routes that
  expose this:
  ```ruby
  resources :templates, only: [ :index, :show, :new, :create, :edit, :update, :destroy ] do
    resources :pages, only: [ :index, :create, :new ]
  end
  resources :pages, only: [ :show ] do
    resources :form_fields, only: [ :index ]
  end
  resources :form_fields, only: [ :show, :edit, :update, :destroy ]
  ```
  (There is a separate `namespace :admin` block at `:2-17` with its own
  Administrate-backed `resources :templates` — that is admin-only and out of
  scope here.)

- Convention: policies subclass `ApplicationPolicy` (`app/policies/application_policy.rb`),
  which exposes `user` and `record`, and `Scope` is initialized with
  `(user, scope)`. Users belong to an account: `User belongs_to :account`
  (`app/models/user.rb:7`); a scribe example of account scoping is
  `ScribeSession.where(account: current_account)`
  (`app/controllers/api/v2/scribe_sessions_controller.rb:85`).

- There are **no** policy tests yet (`test/policies/` does not exist). Model a
  new one after any Minitest unit test; the closest structural exemplars are the
  service unit tests under `test/services/`.

## Commands you will need

| Purpose        | Command                                                                       | Expected on success |
|----------------|-------------------------------------------------------------------------------|---------------------|
| Migrate        | `ASDF_RUBY_VERSION=3.2.2 bin/rails db:migrate`                                 | exit 0              |
| Prepare test DB| `ASDF_RUBY_VERSION=3.2.2 bin/rails db:test:prepare`                            | exit 0              |
| Policy test    | `ASDF_RUBY_VERSION=3.2.2 bin/rails test test/policies/template_policy_test.rb` | all pass            |
| Builder test   | `ASDF_RUBY_VERSION=3.2.2 bin/rails test test/integration/templates_builder_test.rb` | all pass      |
| Full tests     | `ASDF_RUBY_VERSION=3.2.2 bin/rails test`                                       | 0 failures          |
| Lint           | `ASDF_RUBY_VERSION=3.2.2 bin/rubocop`                                          | no offenses         |

## Scope

**In scope** (depends on the chosen path — see Step 0):
- `app/policies/template_policy.rb`
- `test/policies/template_policy_test.rb` (create)
- Path A additionally: `db/migrate/<timestamp>_add_account_to_templates.rb`
  (create), `db/schema.rb` (regenerated by the migration),
  `app/models/template.rb`, `app/controllers/templates_controller.rb`.
- Path B additionally: `config/routes.rb` and/or the policy only.

**Out of scope** (do NOT touch, even though they look related):
- The `namespace :admin` routes and Administrate dashboards
  (`config/routes.rb:2-17`) — admin management of templates is intentional.
- `app/policies/page_policy.rb` / `form_field_policy.rb` beyond what is needed to
  mirror Template ownership — if those policies do not exist or the controllers
  don't use Pundit the same way, STOP and report rather than inventing scope.
- The v1/v2 API template read endpoints (`config/routes.rb:53-54`) — read-only.

## Step 0 (DECISION STOP — do this before any code): pick the ownership model

The current codebase has NO owner column on `templates` and an admin UI that
manages a shared library — consistent with "templates are shared platform
config." But the user-facing controller lets any signed-in user create AND
destroy them, which is only safe if they are tenant-owned. This contradiction is
the root question. **Stop and get an explicit decision** between:

- **Path A (recommended): templates are tenant-owned.** Add `account_id`
  ownership; scope reads and writes to the current user's account. Best if
  clinics create/edit their own forms.
- **Path B: templates are shared platform config.** Users may read, but only
  admins may write; remove/lock the user-facing write routes. Best if the
  library is centrally curated.

Report both to the operator with this recommendation (Path A) and proceed only
with the chosen path. Do not implement both.

## Steps — Path A (tenant-owned; recommended)

### A1: Add a nullable `account_id` to templates, backfill, then enforce

Create a migration `add_account_to_templates`:
```ruby
class AddAccountToTemplates < ActiveRecord::Migration[8.0]
  def change
    add_reference :templates, :account, foreign_key: true, null: true, index: true
  end
end
```
Leave it nullable in this migration (existing rows have no owner yet). If the
operator confirms every existing template should belong to a specific account,
add a separate backfill; otherwise leave legacy rows null (the scope below will
simply exclude them from tenant views, which is safe-by-default).

**Verify**: `ASDF_RUBY_VERSION=3.2.2 bin/rails db:migrate` → exit 0;
`grep -n "account_id" db/schema.rb` shows the column under `templates`.

### A2: Associate the model

In `app/models/template.rb` add:
```ruby
belongs_to :account, optional: true
```
(`optional: true` because legacy rows may be null; new rows get an account in A3.)

**Verify**: `ASDF_RUBY_VERSION=3.2.2 bin/rails runner "Template.new.respond_to?(:account)"` → prints `true`.

### A3: Set the owner on create

In `app/controllers/templates_controller.rb#create` (`:26-36`), set the owner:
```ruby
@template = Template.new(template_params.merge(account: current_user.account))
```

**Verify**: `ASDF_RUBY_VERSION=3.2.2 bin/rails test test/integration/templates_builder_test.rb`
→ all pass (the builder test signs in a user who has an auto-created account, so
create still succeeds).

### A4: Scope the policy to the owning account

Rewrite `app/policies/template_policy.rb` writes and scope:
```ruby
def create?
  user.present?
end

def update?
  owns?
end

def edit?
  update?
end

def destroy?
  owns?
end

class Scope < Scope
  def resolve
    scope.where(account_id: user.account_id)
  end
end

private

def owns?
  user.present? && record.account_id == user.account_id
end
```
Keep `index?`/`show?`/`find_by_domain?`/`new?` as-is unless the operator wants
reads scoped too (note: `show?`/`index?` currently return `true`; the controller
`index` already uses `policy_scope`, so scoping the Scope also scopes the list).

**Verify**: `ASDF_RUBY_VERSION=3.2.2 bin/rails test test/policies/template_policy_test.rb`
(written in Step A5) → all pass.

### A5: Write the policy test

Create `test/policies/template_policy_test.rb`:
```ruby
require "test_helper"

class TemplatePolicyTest < ActiveSupport::TestCase
  def setup
    @account_a = create(:account)
    @user_a = create(:user, account: @account_a)
    @account_b = create(:account)
    @user_b = create(:user, account: @account_b)
    @b_template = create(:template, account: @account_b)
  end

  test "denies update on another account's template" do
    refute TemplatePolicy.new(@user_a, @b_template).update?
  end

  test "denies destroy on another account's template" do
    refute TemplatePolicy.new(@user_a, @b_template).destroy?
  end

  test "allows the owner to update and destroy" do
    assert TemplatePolicy.new(@user_b, @b_template).update?
    assert TemplatePolicy.new(@user_b, @b_template).destroy?
  end

  test "scope returns only the user's account templates" do
    create(:template, account: @account_a)
    scoped = TemplatePolicy::Scope.new(@user_a, Template.all).resolve
    assert scoped.all? { |t| t.account_id == @account_a.id }
    refute_includes scoped, @b_template
  end
end
```

**Verify**: `ASDF_RUBY_VERSION=3.2.2 bin/rails test test/policies/template_policy_test.rb`
→ 4 tests pass.

## Steps — Path B (shared config; only if chosen in Step 0)

### B1: Restrict writes to admins in the policy

Change `create?`/`update?`/`destroy?` to require an admin (use the app's
existing admin check — inspect how `namespace :admin` gates access and mirror
it; if there is no user-level admin flag, STOP and report). Keep the `Scope`
returning `Template.all` (shared read is intentional here).

### B2: Remove the user-facing write routes

In `config/routes.rb:29-39`, reduce the user-facing template/page/form_field
resources to read-only (`only: [:index, :show]`), leaving admin routes intact.

### B3: Policy test (shared variant)

Same file `test/policies/template_policy_test.rb`, asserting a non-admin user is
denied `update?`/`destroy?` and an admin is allowed. Model after A5's structure.

## Test plan

- New file `test/policies/template_policy_test.rb`:
  - Path A: a user from account A is denied `update?` and `destroy?` on account
    B's template; the owner is allowed; `Scope#resolve` excludes other accounts.
  - Path B: a non-admin is denied writes; an admin is allowed.
- Structural pattern: a plain `ActiveSupport::TestCase` using factory_bot
  (`create(:account)`, `create(:user, account:)`, `create(:template, ...)`),
  instantiating the policy directly — mirroring the unit-test style used across
  `test/services/`.
- Regression guard: `test/integration/templates_builder_test.rb` must still pass
  (Path A sets `account:` on create so the signed-in user can still build).
- Verification: `ASDF_RUBY_VERSION=3.2.2 bin/rails test` → 0 failures, new policy
  tests included.

## Done criteria

Machine-checkable. ALL must hold:

- [ ] Step 0 decision recorded (Path A or B) in the PR description
- [ ] `grep -n "Template.all" app/policies/template_policy.rb` — Path A: returns no match (scope is account-scoped); Path B: still present (shared read) with admin-gated writes
- [ ] `test/policies/template_policy_test.rb` exists and asserts cross-account denial
- [ ] `ASDF_RUBY_VERSION=3.2.2 bin/rails test test/policies/template_policy_test.rb` passes
- [ ] `ASDF_RUBY_VERSION=3.2.2 bin/rails test test/integration/templates_builder_test.rb` passes
- [ ] Path A only: `ASDF_RUBY_VERSION=3.2.2 bin/rails db:migrate` exits 0 and `db/schema.rb` shows `account_id` on `templates`
- [ ] `ASDF_RUBY_VERSION=3.2.2 bin/rails test` exits 0 with 0 failures
- [ ] `ASDF_RUBY_VERSION=3.2.2 bin/rubocop` reports no offenses
- [ ] No files outside the in-scope list are modified (`git status`)
- [ ] `plans/README.md` status row updated

## STOP conditions

Stop and report back (do not improvise) if:

- The Step 0 product decision has not been made — do NOT guess.
- The code at any "Current state" location does not match the excerpts (drift).
- Path A: a `NOT NULL` or foreign-key constraint would orphan existing template
  rows that have no obvious owning account (backfill strategy is unclear).
- Path B: there is no existing user-level admin concept to gate writes on
  (report how admin access is currently enforced instead of inventing one).
- Pages/FormFields turn out to be writable through controllers/policies you'd
  need to also scope, and those are not the simple mirrors this plan assumes.

## Maintenance notes

For the human/agent who owns this after the change lands:

- Pages and FormFields inherit ownership transitively via `Template`. If the app
  later lets users hit `PagesController`/`FormFieldsController` write actions
  directly (routes `config/routes.rb:33-37`), their policies must apply the same
  `record.template.account_id == user.account_id` check — verify those policies
  before exposing more page/field write routes.
- A reviewer should scrutinize: the policy scope wiring (does `index` use
  `policy_scope`? yes — `templates_controller.rb:10`), that `create` sets the
  owner (Path A), and that legacy null-owner templates behave safely.
- Deferred: backfilling `account_id` for pre-existing templates and flipping the
  column to `null: false` — do that once every legacy row has a confirmed owner.
