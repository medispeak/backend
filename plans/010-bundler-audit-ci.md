# Plan 010: Add Ruby gem CVE scanning (bundler-audit) to CI

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan
> in `plans/README.md` — unless a reviewer dispatched you and told you they
> maintain the index.
>
> **Drift check (run first)**:
> `git diff --stat 84da325..HEAD -- Gemfile Gemfile.lock .github/workflows/ci.yml`
> If any in-scope file changed since this plan was written, compare the
> "Current state" excerpts against the live code before proceeding; on a
> mismatch, treat it as a STOP condition.

## Status

- **Priority**: P2
- **Effort**: S
- **Risk**: LOW
- **Depends on**: none
- **Category**: dx
- **Planned at**: commit `84da325`, 2026-07-08

## Why this matters

Finding F10: CI statically scans Rails code (brakeman) and JS dependencies
(`importmap audit`), but there is NO scanning of the Ruby gem dependency tree for
known CVEs. A vulnerable transitive gem (the kind bundler-audit flags against the
Ruby Advisory DB) would ship undetected. Adding `bundler-audit` as a dev/test gem
and a CI job that runs `bundle-audit check --update` closes that supply-chain gap
and makes a newly-disclosed gem CVE fail the build.

## Current state

- `.github/workflows/ci.yml` — jobs today are `scan_ruby` (brakeman), `scan_js`
  (`importmap audit`), `lint` (rubocop), and `test`. There is NO gem-CVE job. The
  `scan_ruby` job is the shape to mirror:
  ```yaml
  scan_ruby:
    runs-on: ubuntu-latest

    steps:
      - name: Checkout code
        uses: actions/checkout@v4

      - name: Set up Ruby
        uses: ruby/setup-ruby@v1
        with:
          ruby-version: .ruby-version
          bundler-cache: true

      - name: Scan for common Rails security vulnerabilities using static analysis
        run: bin/brakeman --no-pager
  ```

- `Gemfile:69-78` — the `:development, :test` group has `brakeman` and
  `rubocop-rails-omakase` but no `bundler-audit`:
  ```ruby
  group :development, :test do
    # See https://guides.rubyonrails.org/debugging_rails_applications.html#debugging-with-the-debug-gem
    gem "debug", platforms: %i[ mri windows ], require: "debug/prelude"

    # Static analysis for security vulnerabilities [https://brakemanscanner.org/]
    gem "brakeman", require: false

    # Omakase Ruby styling [https://github.com/rails/rubocop-rails-omakase/]
    gem "rubocop-rails-omakase", require: false
  end
  ```

- The bundler-audit gem is named `bundler-audit`; it installs a `bundle-audit`
  executable; the scan command is `bundle-audit check --update` (the `--update`
  refreshes the local Ruby Advisory DB first). CI jobs run Ruby via
  `ruby-version: .ruby-version` with `bundler-cache: true`.

## Commands you will need

| Purpose        | Command                                                                       | Expected on success |
|----------------|-------------------------------------------------------------------------------|---------------------|
| Install gem    | `ASDF_RUBY_VERSION=3.2.2 bundle install`                                       | exit 0; Gemfile.lock updated |
| Run audit      | `ASDF_RUBY_VERSION=3.2.2 bundle exec bundle-audit check --update`              | "No vulnerabilities found" (exit 0) |
| YAML sanity    | `ASDF_RUBY_VERSION=3.2.2 ruby -ryaml -e 'YAML.load_file(%q(.github/workflows/ci.yml)); puts :ok'` | prints `ok` |
| Lint           | `ASDF_RUBY_VERSION=3.2.2 bin/rubocop`                                          | no offenses         |

## Scope

**In scope** (the only files you should modify):
- `Gemfile`
- `Gemfile.lock` (updated by `bundle install` — do not hand-edit)
- `.github/workflows/ci.yml`

**Out of scope** (do NOT touch, even though they look related):
- The existing `scan_ruby`, `scan_js`, `lint`, `test` jobs — add a new job, do
  not modify these.
- Upgrading any application gem to resolve a reported CVE — if the audit reports
  a vulnerability, STOP and report (that is a separate remediation decision), do
  NOT bump gems here.
- Adding a `.bundler-audit.yml` ignore file — do not suppress findings in this
  plan.

## Git workflow

- Branch: `advisor/010-bundler-audit-ci`
- One commit; short imperative subject (e.g. `Add bundler-audit gem CVE scan to CI`).
- Do NOT push or open a PR unless the operator instructed it.

## Steps

### Step 1: Add the `bundler-audit` gem

In `Gemfile`, add to the `group :development, :test do` block (alongside
`brakeman`):
```ruby
  # Scan the Ruby gem dependency tree for known CVEs [https://github.com/rubysec/bundler-audit]
  gem "bundler-audit", require: false
```
Then install so `Gemfile.lock` is updated:
```
ASDF_RUBY_VERSION=3.2.2 bundle install
```

**Verify**: `grep -n "bundler-audit" Gemfile Gemfile.lock` → present in both.

### Step 2: Confirm the audit runs clean locally

```
ASDF_RUBY_VERSION=3.2.2 bundle exec bundle-audit check --update
```

**Verify**: command exits 0 and prints "No vulnerabilities found". If it reports
one or more advisories, do NOT proceed to "fix" them here — go to STOP conditions.

### Step 3: Add a CI job mirroring `scan_ruby`

In `.github/workflows/ci.yml`, add a new job under `jobs:` (place it right after
`scan_ruby`). Match the existing indentation (2 spaces for the job key):
```yaml
  scan_deps:
    runs-on: ubuntu-latest

    steps:
      - name: Checkout code
        uses: actions/checkout@v4

      - name: Set up Ruby
        uses: ruby/setup-ruby@v1
        with:
          ruby-version: .ruby-version
          bundler-cache: true

      - name: Scan Ruby dependencies for known CVEs
        run: bundle exec bundle-audit check --update
```

**Verify**:
`ASDF_RUBY_VERSION=3.2.2 ruby -ryaml -e 'y = YAML.load_file(%q(.github/workflows/ci.yml)); abort("missing job") unless y.dig("jobs", "scan_deps"); puts :ok'`
→ prints `ok`.

## Test plan

This is tooling; there is no unit test. Verification is the audit running and the
CI job existing:

- `ASDF_RUBY_VERSION=3.2.2 bundle exec bundle-audit check --update` runs and
  exits 0 ("No vulnerabilities found").
- `.github/workflows/ci.yml` parses as valid YAML and contains a `scan_deps` job
  whose step runs `bundle exec bundle-audit check --update`.
- Regression sanity: `ASDF_RUBY_VERSION=3.2.2 bin/rails test` still exits 0
  (adding a dev/test gem must not affect the suite).

## Done criteria

Machine-checkable. ALL must hold:

- [ ] `grep -n "bundler-audit" Gemfile` shows it in the `:development, :test` group
- [ ] `grep -n "bundler-audit" Gemfile.lock` shows the resolved gem
- [ ] `ASDF_RUBY_VERSION=3.2.2 bundle exec bundle-audit check --update` exits 0
- [ ] `.github/workflows/ci.yml` has a `scan_deps` job running `bundle exec bundle-audit check --update` (YAML parses; `jobs.scan_deps` present)
- [ ] `ASDF_RUBY_VERSION=3.2.2 bin/rubocop` reports no offenses
- [ ] `ASDF_RUBY_VERSION=3.2.2 bin/rails test` exits 0 (unaffected)
- [ ] No files outside the in-scope list are modified (`git status`)
- [ ] `plans/README.md` status row updated

## STOP conditions

Stop and report back (do not improvise) if:

- `Gemfile` / `.github/workflows/ci.yml` no longer match the "Current state"
  excerpts (drift) — e.g. a `scan_deps`/bundler-audit job already exists.
- `bundle install` fails to resolve `bundler-audit` (version conflict) — report
  the conflict; do not force unrelated gem upgrades.
- `bundle-audit check --update` reports one or more vulnerable gems. Capture the
  full report and STOP — remediation (gem upgrades, or a justified, reviewed
  ignore) is a separate decision, not part of wiring the scanner.

## Maintenance notes

For the human/agent who owns this after the change lands:

- The new job makes CI **fail** whenever a gem in the tree has a known advisory.
  That is the point, but it means a newly-disclosed CVE can turn the build red
  without any code change — expected behavior; remediate by upgrading the gem.
- If a finding is a documented false positive or cannot be fixed immediately, the
  supported escape hatch is a reviewed `.bundler-audit.yml` with an explicit
  `ignore:` list (out of scope here) — never blanket-disable the job.
- `--update` refreshes the advisory DB on each run so CI catches newly-published
  CVEs; keep it.
- A reviewer should confirm the job actually gates (appears as a required check)
  rather than running informationally.
