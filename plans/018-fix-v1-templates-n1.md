# Plan 018: Eager-load pages + form_fields in the v1 template endpoints (kill the per-page N+1)

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan
> in `plans/README.md` — unless a reviewer dispatched you and told you they
> maintain the index.
>
> **Drift check (run first)**:
> `git diff --stat 84da325..HEAD -- app/controllers/api/v1/templates_controller.rb app/views/templates/_template.json.jbuilder app/views/pages/_page.json.jbuilder`
> If any in-scope/reference file changed since this plan was written, compare the
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

The v1 template endpoints (`show` and `find_by_domain`) render a template with
its `pages`, and each page with its `form_fields`, via jbuilder partials. Neither
action eager-loads those associations, so rendering fires one
`SELECT form_fields WHERE page_id = ?` **per page** — an N+1 that grows with the
number of pages in a template. `find_by_domain` is the webapp's hot per-domain
config lookup (called on the collection route to resolve which template a clinic
domain uses), so this N+1 sits on a frequently-hit path.

After this plan lands: both actions eager-load `pages: :form_fields`, so the
render issues a **constant** number of queries regardless of how many pages or
fields the template has. The rendered JSON is byte-for-byte unchanged.

## Current state

Files involved and their roles:

- `app/controllers/api/v1/templates_controller.rb` — the v1 controller; `show`
  and `find_by_domain` both load the template without eager-loading.
- `app/views/templates/show.json.jbuilder` — renders `templates/_template`
  (read-only reference).
- `app/views/templates/_template.json.jbuilder` — iterates `template.pages`
  (read-only reference).
- `app/views/pages/_page.json.jbuilder` — iterates `page.form_fields` per page;
  this is where the N+1 SELECTs fire (read-only reference).
- `test/integration/api/v1/templates_test.rb` — **does not exist yet**; you will
  create it, modeled after `test/integration/api/v1/transcriptions_golden_test.rb`.

The two actions that load without eager-loading,
`app/controllers/api/v1/templates_controller.rb:1-23`:

```ruby
class Api::V1::TemplatesController < Api::BaseController
  # GET /api/v1/template/:id
  def show
    @template = Template.active.find_by(id: params[:id])
    if @template
      render "templates/show"
    else
      raise GenericException.new(message: "Template not found", code: :not_found)
    end
  end

  # GET /api/v1/template/find_by_domain/
  def find_by_domain
    origin = find_host(request)
    domain = Domain.find_by(fqdn: origin)
    @template = Template.active.find_by(id: domain&.template_id)

    if @template
      render "templates/show"
    else
      raise GenericException.new(message: "Template not found for the given domain: #{origin}", code: :not_found)
    end
  end
```

(The `# GET /api/v1/template/...` comments are stale — the actual routes are
plural; see "Routes" below.)

The render chain that N+1s.
`app/views/templates/show.json.jbuilder`:

```ruby
json.partial! "templates/template", template: @template
```

`app/views/templates/_template.json.jbuilder`:

```ruby
json.extract! template, :id, :name, :description, :archived, :created_at, :updated_at
json.pages template.pages do |page|
  json.partial! "pages/page", page: page
end
```

`app/views/pages/_page.json.jbuilder` (the `page.form_fields` read is the N+1):

```ruby
json.extract! page, :id, :template_id, :name, :created_at, :updated_at
json.url page_url(page, format: :json)
json.form_fields page.form_fields do |form_field|
  json.partial! "form_fields/form_field", form_field: form_field
end
```

The associations exist on the models:
- `app/models/template.rb:3` — `has_many :pages, dependent: :destroy`
- `app/models/page.rb:3` — `has_many :form_fields, dependent: :destroy`
- `app/models/template.rb:12` — `scope :active, -> { where(archived: false) }`

**Routes (verified with `bin/rails routes`):**
- `GET /api/v1/templates/:id` → `api/v1/templates#show`
- `GET /api/v1/templates/find_by_domain` → `api/v1/templates#find_by_domain`

**Auth + errors (verified):** `Api::BaseController` requires a Bearer token
(`prepend_before_action :authenticate_api_token!`); missing/invalid token →
`401`. `GenericException.new(code: :not_found)` is rendered by `ExceptionHandler`
as HTTP `404` with body `{ error: { message:, code: "not_found", request_id: } }`.

**`find_by_domain` host resolution (verified):** `find_host(request)` returns
`extract_host(request.origin) || extract_host(request.original_url)`, and
`extract_host` pulls the host out of `https?://([^/]+)`. So setting the request
`Origin` header to `https://clinic.example.com` makes `origin == "clinic.example.com"`,
and the action then does `Domain.find_by(fqdn: "clinic.example.com")`. Seed the
`Domain` with the **host only** (no scheme) as its `fqdn`.

**Convention:** v1 renders through jbuilder views under `app/views/` (unlike v2's
plain-Ruby serializers). The eager-load happens in the controller; the views do
not change. `Domain` has no factory — create it with `Domain.create!(fqdn:, template:)`
(`app/models/domain.rb` requires `fqdn` present + unique and `template` present).

## Commands you will need

| Purpose | Command | Expected on success |
|---|---|---|
| Prepare test DB | `ASDF_RUBY_VERSION=3.2.2 bin/rails db:test:prepare` | exit 0 |
| Single test file | `ASDF_RUBY_VERSION=3.2.2 bin/rails test test/integration/api/v1/templates_test.rb` | 0 failures, 0 errors |
| Tests (all) | `ASDF_RUBY_VERSION=3.2.2 bin/rails test` | 0 failures |
| Lint | `ASDF_RUBY_VERSION=3.2.2 bin/rubocop` | no offenses |
| Confirm routes | `ASDF_RUBY_VERSION=3.2.2 bin/rails routes -g templates` | shows the two `/api/v1/templates` routes above |

(The `ASDF_RUBY_VERSION=3.2.2` prefix is required on this machine so asdf
resolves Ruby 3.2.2; without it `bin/rails` may not run.)

## Scope

**In scope** (the only files you should modify or create):
- `app/controllers/api/v1/templates_controller.rb` (modify — 2 lines)
- `test/integration/api/v1/templates_test.rb` (create)

**Out of scope** (do NOT touch, even though they look related):
- `app/views/templates/_template.json.jbuilder`, `app/views/pages/_page.json.jbuilder`,
  `app/views/templates/show.json.jbuilder`, `app/views/form_fields/_form_field.json.jbuilder`
  — the views are correct; eager-loading in the controller makes their
  association reads hit the preloaded cache. Changing them risks altering the
  response shape.
- The rendered JSON shape — clients depend on it exactly as-is.
- `app/models/*` — associations and the `active` scope are already correct.

## Git workflow

- Branch: `advisor/018-fix-v1-templates-n1`
- Commit per logical unit; message style matches the repo log (short imperative,
  e.g. `git log` shows "Add …", "Fix …"). Suggested: `Eager-load pages/form_fields in v1 template endpoints`.
- Do NOT push or open a PR unless the operator instructed it.

## Steps

### Step 1: Eager-load `pages: :form_fields` in both actions

Edit `app/controllers/api/v1/templates_controller.rb`. Change only the two
`Template.active.find_by(...)` lines:

In `show` (line 4), replace:

```ruby
@template = Template.active.find_by(id: params[:id])
```

with:

```ruby
@template = Template.active.includes(pages: :form_fields).find_by(id: params[:id])
```

In `find_by_domain` (line 15), replace:

```ruby
@template = Template.active.find_by(id: domain&.template_id)
```

with:

```ruby
@template = Template.active.includes(pages: :form_fields).find_by(id: domain&.template_id)
```

Nothing else changes. `Model.includes(...).find_by(...)` loads the matched record
and preloads its `pages` and each page's `form_fields`, so the jbuilder partials
read from the preloaded cache instead of issuing per-page queries.

**Verify**: `grep -n "includes(pages: :form_fields)" app/controllers/api/v1/templates_controller.rb`
→ 2 matches.

### Step 2: Create the v1 templates integration test

See the Test plan below, then run the file.

**Verify**: `ASDF_RUBY_VERSION=3.2.2 bin/rails test test/integration/api/v1/templates_test.rb`
→ 0 failures, 0 errors.

## Test plan

Create `test/integration/api/v1/templates_test.rb`, modeled structurally after
`test/integration/api/v1/transcriptions_golden_test.rb` (Bearer-token auth via
`@headers`, factory-built fixtures). The suite has **no** existing query-count
helper, so add one as a private method (same helper used across these perf
plans):

```ruby
require "test_helper"

class Api::V1::TemplatesTest < ActionDispatch::IntegrationTest
  setup do
    @token = create(:api_token)
    @account = @token.account
    @headers = { "Authorization" => "Bearer #{@token.raw_token}" }
  end

  test "show returns the template with nested pages and form fields" do
    template = create(:template)
    page = create(:page, template: template)
    create(:form_field, page: page, title: "complaint")

    get "/api/v1/templates/#{template.id}", headers: @headers

    assert_response :ok
    body = JSON.parse(response.body)
    assert_equal template.id, body["id"]
    assert_equal 1, body["pages"].size
    assert_equal page.id, body["pages"][0]["id"]
    assert_equal 1, body["pages"][0]["form_fields"].size
  end

  test "find_by_domain resolves the template from the Origin host" do
    template = create(:template)
    page = create(:page, template: template)
    create(:form_field, page: page, title: "complaint")
    Domain.create!(fqdn: "clinic.example.com", template: template)

    get "/api/v1/templates/find_by_domain",
        headers: @headers.merge("Origin" => "https://clinic.example.com")

    assert_response :ok
    body = JSON.parse(response.body)
    assert_equal template.id, body["id"]
    assert_equal 1, body["pages"][0]["form_fields"].size
  end

  test "find_by_domain issues a bounded query count regardless of page/field counts" do
    # Small template: 1 page, 1 field.
    small = create(:template)
    small_page = create(:page, template: small)
    create(:form_field, page: small_page)
    Domain.create!(fqdn: "small.example.com", template: small)

    q_small = count_ar_queries do
      get "/api/v1/templates/find_by_domain",
          headers: @headers.merge("Origin" => "https://small.example.com")
    end
    assert_response :ok

    # Large template: 3 pages, 3 fields each.
    large = create(:template)
    3.times do
      p = create(:page, template: large)
      3.times { create(:form_field, page: p) }
    end
    Domain.create!(fqdn: "large.example.com", template: large)

    q_large = count_ar_queries do
      get "/api/v1/templates/find_by_domain",
          headers: @headers.merge("Origin" => "https://large.example.com")
    end
    assert_response :ok

    assert_equal q_small, q_large,
      "query count grew with more pages/fields -> N+1 not fixed (got #{q_small} then #{q_large})"
  end

  test "find_by_domain returns 404 for an unknown domain" do
    get "/api/v1/templates/find_by_domain",
        headers: @headers.merge("Origin" => "https://nope.example.com")

    assert_response :not_found
    assert_equal "not_found", JSON.parse(response.body).dig("error", "code")
  end

  test "unauthenticated request is rejected" do
    get "/api/v1/templates/find_by_domain"
    assert_response :unauthorized
  end

  private

  # Counts real ActiveRecord SELECT/INSERT/UPDATE/DELETE queries issued inside
  # the block, ignoring schema reflection, cache hits, and transaction control
  # statements. Used to prove the render does not N+1 across pages/fields.
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
end
```

Notes for the executor:
- The **bounded-query test** is the core regression test: on the current
  (unfixed) code, the large template renders one extra `form_fields` query per
  page, so `q_large > q_small`; after Step 1 the counts are equal. It compares
  counts across two templates (not an absolute number), so it is robust to
  constant per-request overhead (auth touches `last_used_at`, etc.).
- `@token.raw_token` is the plaintext token exposed by the `:api_token` factory
  (same pattern as `transcriptions_golden_test.rb:9-10`).
- Do NOT set `Content-Type`; these are GETs with no body.

Verification: `ASDF_RUBY_VERSION=3.2.2 bin/rails test test/integration/api/v1/templates_test.rb`
→ all pass.

## Done criteria

Machine-checkable. ALL must hold:

- [ ] `ASDF_RUBY_VERSION=3.2.2 bin/rails test test/integration/api/v1/templates_test.rb` → 0 failures, 0 errors, includes the bounded-query test
- [ ] `ASDF_RUBY_VERSION=3.2.2 bin/rails test` → 0 failures
- [ ] `ASDF_RUBY_VERSION=3.2.2 bin/rubocop` → no offenses
- [ ] `grep -n "includes(pages: :form_fields)" app/controllers/api/v1/templates_controller.rb` → 2 matches
- [ ] `git diff --name-only` shows ONLY `app/controllers/api/v1/templates_controller.rb` and the new `test/integration/api/v1/templates_test.rb` (plus `plans/README.md`)
- [ ] `plans/README.md` status row updated

## STOP conditions

Stop and report back (do not improvise) if:

- The "Current state" excerpts don't match the live code (files drifted since
  commit `84da325`) — especially if the jbuilder partials no longer iterate
  `template.pages` / `page.form_fields`, or if the routes differ from the two
  listed above (`bin/rails routes -g templates`).
- The bounded-query test still shows `q_large > q_small` after Step 1 (preloading
  did not take effect) — investigate before improvising; do not "fix" it by
  editing the views.
- `find_by_domain` does not resolve the template in the test (e.g. `request.origin`
  is nil so the host falls back to `original_url`) — report the observed
  `origin`/host rather than guessing; do not change `find_host`/`extract_host`
  (out of scope).
- Any verification fails twice after a reasonable fix attempt.

## Maintenance notes

For whoever owns this after it lands:

- If a new nested association is ever rendered by `_template`/`_page` (e.g. page
  metadata, field options loaded from another table), add it to the
  `includes(...)` in **both** actions, or the N+1 returns. The bounded-query test
  will catch a per-page/per-field regression, but only for associations it
  exercises.
- `show` and `find_by_domain` now duplicate the `includes(pages: :form_fields)`
  fragment. If a third template-loading action appears, consider extracting a
  private `active_template_scope` helper — deferred here to keep the diff to two
  lines.
- Reviewer should scrutinize: the eager-load is applied to `Template.active`
  (not a bare `Template`), so archived templates are still excluded, and the
  rendered JSON is unchanged (diff the response against a pre-change capture if
  in doubt).
