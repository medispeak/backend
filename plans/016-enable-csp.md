# Plan 016: Enable a Content Security Policy (report-only first, then enforce)

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan
> in `plans/README.md` — unless a reviewer dispatched you and told you they
> maintain the index.
>
> **Drift check (run first)**:
> `git diff --stat 84da325..HEAD -- config/initializers/content_security_policy.rb app/views/layouts/application.html.erb`
> If any in-scope file changed since this plan was written, compare the
> "Current state" excerpts against the live code before proceeding; on a
> mismatch, treat it as a STOP condition.

## Status

- **Priority**: P2
- **Effort**: M
- **Risk**: MED
- **Depends on**: none
- **Category**: security
- **Planned at**: commit `84da325`, 2026-07-08

## Why this matters

The app ships with **no** Content Security Policy — the entire policy initializer
is commented out, so no `Content-Security-Policy` header is sent on any HTML
response. CSP is the primary in-depth defense against cross-site scripting: with
it off, any reflected/stored XSS runs with full privileges (inline scripts,
arbitrary external script loads, data exfiltration). This plan turns on a
baseline policy compatible with the app's front-end stack (importmap +
tailwindcss-rails, plus the Administrate admin UI), shipping in **report-only**
mode first to catch violations without breaking pages, then flipping to enforce.

## Current state

- `config/initializers/content_security_policy.rb` — the whole policy is
  commented out (the file is effectively a no-op; every line is a comment). The
  commented template it ships with:
  ```ruby
  # Rails.application.configure do
  #   config.content_security_policy do |policy|
  #     policy.default_src :self, :https
  #     policy.font_src    :self, :https, :data
  #     policy.img_src     :self, :https, :data
  #     policy.object_src  :none
  #     policy.script_src  :self, :https
  #     policy.style_src   :self, :https
  #   end
  #   config.content_security_policy_nonce_generator = ->(request) { request.session.id.to_s }
  #   config.content_security_policy_nonce_directives = %w(script-src style-src)
  #   # config.content_security_policy_report_only = true
  # end
  ```
  Result: no CSP header is emitted at all.

- The application layout already renders the nonce meta tag and uses importmap
  and precompiled stylesheets, so a nonce-based policy will "just work" for the
  app's own scripts/styles:
  - `app/views/layouts/application.html.erb:9` → `<%= csp_meta_tag %>`
  - `:39` → `<%= stylesheet_link_tag "tailwind", "inter-font", "data-turbo-track": "reload" %>`
    (tailwindcss-rails precompiles a static CSS file served same-origin)
  - `:40` → `<%= javascript_importmap_tags %>` (importmap emits a JSON importmap
    `<script>` + module preloads; when a nonce generator is configured Rails/
    importmap-rails attaches the nonce automatically)

- The admin UI is **Administrate** (git-pinned beta:
  `gem "administrate", github: "thoughtbot/administrate", branch: "main"` in
  `Gemfile`). Administrate renders its own layout (views live under
  `app/views/admin/...`, e.g. `app/views/admin/model_assignments/index.html.erb`)
  and may emit inline `style`/`script` that a strict policy blocks. This is the
  main risk surface — hence report-only first.

- There are existing `ActionDispatch::IntegrationTest`s that fetch HTML pages,
  suitable as a header-assertion pattern:
  - `test/integration/templates_builder_test.rb` (`get new_template_path` →
    `assert_response :success`, includes `Devise::Test::IntegrationHelpers`).
  - The unauthenticated Devise sign-in page is `GET /users/sign_in`
    (route helper `new_user_session_path`) and returns HTML with no login —
    ideal for asserting the header on a public page.

## Commands you will need

| Purpose        | Command                                                                | Expected on success |
|----------------|------------------------------------------------------------------------|---------------------|
| CSP test       | `ASDF_RUBY_VERSION=3.2.2 bin/rails test test/integration/csp_header_test.rb` | all pass       |
| Full tests     | `ASDF_RUBY_VERSION=3.2.2 bin/rails test`                                | 0 failures          |
| System tests   | `ASDF_RUBY_VERSION=3.2.2 bin/rails test:system`                         | pass                |
| Lint           | `ASDF_RUBY_VERSION=3.2.2 bin/rubocop config/initializers/content_security_policy.rb` | no offenses |
| Manual check   | `ASDF_RUBY_VERSION=3.2.2 bin/rails runner "puts Rails.application.config.content_security_policy_report_only"` | prints `true` (phase 1) |

## Scope

**In scope** (the only files you should modify):
- `config/initializers/content_security_policy.rb`
- `test/integration/csp_header_test.rb` (create)

**Out of scope** (do NOT touch, even though they look related):
- `app/views/layouts/application.html.erb` — it already has `csp_meta_tag`;
  do NOT restructure the head. If a specific inline script/style must be
  nonce-tagged to satisfy the policy, STOP and report which one (that is a
  content change beyond this initializer-scoped plan).
- Administrate views / admin layout — do NOT edit vendored/admin templates to
  satisfy the policy; if the admin UI breaks under enforce, keep report-only for
  admin and report (see STOP conditions).
- Any `force_ssl` / other security header config.

## Steps

### Step 1: Define a baseline policy in report-only mode

Replace the commented body of `config/initializers/content_security_policy.rb`
with an active, nonce-based policy shipped in **report-only** first:
```ruby
Rails.application.configure do
  config.content_security_policy do |policy|
    policy.default_src :self
    policy.font_src    :self, :data
    policy.img_src     :self, :data, :https
    policy.object_src  :none
    policy.script_src  :self
    policy.style_src   :self
    policy.connect_src :self
    policy.base_uri    :self
    policy.frame_ancestors :self
    # policy.report_uri "/csp-violation-report-endpoint"  # wire up if a collector exists
  end

  # Nonce for importmap + any permitted inline script/style.
  config.content_security_policy_nonce_generator = ->(request) { request.session.id.to_s }
  config.content_security_policy_nonce_directives = %w[script-src style-src]

  # PHASE 1: observe violations without breaking pages. Flip to false in Step 4.
  config.content_security_policy_report_only = true
end
```
Notes:
- `default_src :self` + `object_src :none` is the safe baseline the finding asks
  for. `img_src` allows `:https`/`:data` because marketing/OG images and data
  URIs are common; tighten later if desired.
- tailwindcss-rails serves a precompiled same-origin stylesheet, so
  `style-src :self` (plus the nonce for any inline `<style>`) is expected to
  cover it.

**Verify**:
`ASDF_RUBY_VERSION=3.2.2 bin/rails runner "puts Rails.application.config.content_security_policy_report_only"`
→ prints `true`.

### Step 2: Add the header-presence integration test

Create `test/integration/csp_header_test.rb`, modeled on the existing
integration tests. Assert the report-only header is present on a public HTML
page (the Devise sign-in page needs no auth):
```ruby
require "test_helper"

class CspHeaderTest < ActionDispatch::IntegrationTest
  test "sends a CSP report-only header on an HTML page" do
    get new_user_session_path
    assert_response :success

    header = response.headers["Content-Security-Policy-Report-Only"] ||
             response.headers["Content-Security-Policy"]
    assert header.present?, "expected a CSP header to be set"
    assert_includes header, "default-src 'self'"
    assert_includes header, "object-src 'none'"
  end
end
```

**Verify**: `ASDF_RUBY_VERSION=3.2.2 bin/rails test test/integration/csp_header_test.rb`
→ passes.

### Step 3: Exercise the app under report-only and collect violations

Run the full and system suites; report-only must not break any page, and browser
console `Report-Only` violations are informational. Pay special attention to the
Administrate admin pages and the importmap-driven pages.

**Verify**:
- `ASDF_RUBY_VERSION=3.2.2 bin/rails test` → 0 failures.
- `ASDF_RUBY_VERSION=3.2.2 bin/rails test:system` → pass (system tests drive real
  pages; a report-only policy should not fail them).
- Manually (or via the operator) load `/`, a template builder page, and `/admin`
  and record any `Content-Security-Policy-Report-Only` console violations. If the
  admin UI reports violations that would require `unsafe-inline`, STOP and report
  before enforcing (see STOP conditions).

### Step 4: Flip to enforce (only after Step 3 is clean)

Once no blocking violations remain, set:
```ruby
config.content_security_policy_report_only = false
```
in the same initializer, and update the Step 2 test to assert the enforced header
name instead:
```ruby
header = response.headers["Content-Security-Policy"]
assert header.present?
```

**Verify**:
- `ASDF_RUBY_VERSION=3.2.2 bin/rails runner "puts Rails.application.config.content_security_policy_report_only"`
  → prints `false`.
- `ASDF_RUBY_VERSION=3.2.2 bin/rails test test/integration/csp_header_test.rb` →
  passes with the enforced-header assertion.
- `ASDF_RUBY_VERSION=3.2.2 bin/rails test:system` → pass (no page broken by
  enforcement).

If the admin UI cannot be made compatible without `unsafe-inline`, keep
report-only for now and STOP: report that admin needs remediation before enforce.

## Test plan

- New file `test/integration/csp_header_test.rb`:
  - Phase 1 (report-only): asserts a `Content-Security-Policy-Report-Only`
    header is present on `GET /users/sign_in` and contains `default-src 'self'`
    and `object-src 'none'`.
  - Phase 2 (enforce): flip the assertion to `Content-Security-Policy`.
- Structural pattern: `test/integration/templates_builder_test.rb`
  (`ActionDispatch::IntegrationTest`, `get` an HTML page, `assert_response`).
- Verification: `ASDF_RUBY_VERSION=3.2.2 bin/rails test test/integration/csp_header_test.rb`
  and the full suite → all pass.

## Done criteria

Machine-checkable. ALL must hold:

- [ ] `config/initializers/content_security_policy.rb` defines an active policy (a non-commented `config.content_security_policy do` block)
- [ ] `ASDF_RUBY_VERSION=3.2.2 bin/rails runner "puts Rails.application.config.content_security_policy.present?"` prints `true`
- [ ] `test/integration/csp_header_test.rb` exists and asserts a CSP (or CSP-Report-Only) header on an HTML page
- [ ] `ASDF_RUBY_VERSION=3.2.2 bin/rails test test/integration/csp_header_test.rb` passes
- [ ] `ASDF_RUBY_VERSION=3.2.2 bin/rails test` exits 0 with 0 failures
- [ ] `ASDF_RUBY_VERSION=3.2.2 bin/rails test:system` passes
- [ ] `ASDF_RUBY_VERSION=3.2.2 bin/rubocop config/initializers/content_security_policy.rb` reports no offenses
- [ ] No files outside the in-scope list are modified (`git status`)
- [ ] `plans/README.md` status row updated
- [ ] The phase reached (report-only vs enforce) is stated in the PR description

## STOP conditions

Stop and report back (do not improvise) if:

- The initializer is not fully commented as in "Current state" (drift — someone
  already configured CSP).
- Under enforcement, the **Administrate** admin UI (or importmap assets) breaks
  and the only fix is `unsafe-inline`/`unsafe-eval` or editing vendored/admin
  views. Do NOT weaken the policy to `unsafe-inline` globally or edit Administrate
  templates — report that admin needs a nonce/remediation pass first, and leave
  the policy in report-only.
- `csp_meta_tag` / `javascript_importmap_tags` are no longer in the layout
  (`app/views/layouts/application.html.erb:9,40`) — the nonce plumbing this plan
  relies on is missing.
- System tests fail specifically because of the policy (not a pre-existing flake).

## Maintenance notes

For the human/agent who owns this after the change lands:

- The policy uses `request.session.id.to_s` as the nonce source (Rails' default
  suggestion). If sessions are disabled for some endpoints, the nonce would be
  empty there — verify nonce-bearing pages always have a session.
- A reviewer should scrutinize: whether enforcement (`report_only = false`) was
  actually reached or intentionally deferred; whether any directive was widened
  (e.g. `img_src :https`) and whether that is acceptable; and that no
  `unsafe-inline` crept in.
- Deferred: wiring `report_uri` to a real violation collector, and tightening
  `img_src`/`connect_src` once real traffic confirms what pages need. Enforcing
  CSP on the Administrate admin area may require a follow-up remediation pass on
  its inline styles/scripts — flag it if you left admin in report-only.
