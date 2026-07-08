# Plan 011: Migrate the app off EOL Ruby 3.2.2 onto Ruby 3.4.x

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan
> in `plans/README.md` — unless a reviewer dispatched you and told you they
> maintain the index.
>
> **Drift check (run first)**:
> `git diff --stat 84da325..HEAD -- .ruby-version Dockerfile Gemfile Gemfile.lock docs/development_setup.md`
> If any in-scope file changed since this plan was written, compare the
> "Current state" excerpts against the live code before proceeding; on a
> mismatch, treat it as a STOP condition.

## Status

- **Priority**: P1
- **Effort**: M
- **Risk**: MED
- **Depends on**: none
- **Category**: tech-debt
- **Planned at**: commit `84da325`, 2026-07-08

## Why this matters

The app runs Ruby 3.2.2, which reached end-of-life on 2026-03-31 and no longer
receives security patches. `bin/brakeman` flags this as a warning. A separate,
compounding problem: `docs/development_setup.md` tells new developers to run
`asdf install`, which reads a `.tool-versions` file — but that file does not
exist, and `.ruby-version` holds the value `ruby-3.2.2` whose `ruby-` prefix
asdf cannot resolve. So a fresh checkout cannot select the right Ruby via asdf
at all. This plan moves the runtime to a supported Ruby 3.4.x and fixes the
asdf resolution so setup works and the EOL warning clears.

## Current state

The facts the executor needs, inlined:

- `.ruby-version` — pins the Ruby version for rbenv/asdf/CI. Current contents
  (the whole file, one line):
  ```
  ruby-3.2.2
  ```
  The `ruby-` prefix is invalid for asdf's ruby plugin (asdf expects a bare
  version like `3.4.3`). rbenv tolerates the prefix; asdf does not.

- `Dockerfile:1` — pins the container base image:
  ```
  ARG RUBY_VERSION=3.2.2
  FROM docker.io/library/ruby:$RUBY_VERSION-slim AS base
  ```

- `Gemfile` — has **no** `ruby "x.y.z"` directive (confirmed: `Gemfile.lock`
  has no `RUBY VERSION` stanza). This keeps the blast radius small — there is
  no third place asserting the version to keep in sync.

- `docs/development_setup.md:35` — the setup instruction that is currently
  broken because no `.tool-versions` exists:
  > Use [asdf](https://asdf-vm.com/) to install Ruby and Node.js. Simply run
  > `asdf install` from the project directory. It'll read the required versions
  > from the `.tool-versions` file and install them.

- There is **no** `.tool-versions` file in the repo root today
  (`ls .tool-versions` → "No such file or directory").

- Environment fact: asdf on this machine already has Ruby 3.4.1, 3.4.2, and
  3.4.3 installed. Pick the newest that `bundle install` succeeds on; this plan
  uses `3.4.3` in examples — substitute the version you land on consistently.

- The git-pinned Administrate beta is the least predictable dependency under a
  Ruby bump. In `Gemfile`:
  ```
  gem "administrate", github: "thoughtbot/administrate", branch: "main"
  ```

## Commands you will need

| Purpose        | Command                                            | Expected on success |
|----------------|----------------------------------------------------|---------------------|
| Bundle install | `ASDF_RUBY_VERSION=3.4.3 bundle install`           | exit 0, resolves    |
| Tests          | `ASDF_RUBY_VERSION=3.4.3 bin/rails test`           | 0 failures          |
| System tests   | `ASDF_RUBY_VERSION=3.4.3 bin/rails test:system`    | pass                |
| Lint           | `ASDF_RUBY_VERSION=3.4.3 bin/rubocop`              | no offenses         |
| Security scan  | `ASDF_RUBY_VERSION=3.4.3 bin/brakeman --no-pager`  | no EOL-Ruby warning |
| Ruby version   | `ruby -v` (from repo root, after `.tool-versions`) | `ruby 3.4.3...`     |

Note: before `.tool-versions` lands, commands need the `ASDF_RUBY_VERSION=3.4.3`
prefix because `.ruby-version`'s `ruby-` prefix breaks asdf resolution. After
Step 1 lands a valid `.tool-versions`, the bare `ruby -v` should report 3.4.x.

## Scope

**In scope** (the only files you should modify):
- `.ruby-version`
- `.tool-versions` (create)
- `Dockerfile`
- `docs/development_setup.md` (only if a code change forces a doc correction)
- Any application source file that emits a **Ruby 3.4 deprecation** the suite
  surfaces (e.g. a gem-independent deprecation you must silence) — but only the
  minimal edit to clear the deprecation. If a fix looks larger than a one-liner,
  STOP and report.

**Out of scope** (do NOT touch, even though they look related):
- `Gemfile` version constraints — do NOT bump or unpin gems to chase a build
  failure without reporting first (see STOP conditions). Adding a `ruby`
  directive to the Gemfile is also out of scope; the two-file pin
  (`.ruby-version` + `.tool-versions`) is intentional.
- CI workflow files — not part of this change.
- Any refactor unrelated to a 3.4 deprecation.

## Git workflow

- Branch: `advisor/011-migrate-ruby-3.4`
- Commit per logical unit; short imperative subject lines (match repo style,
  e.g. `Pin Ruby 3.4.3 via .ruby-version and .tool-versions`).
- Do NOT push or open a PR unless the operator instructed it.

## Steps

### Step 1: Set a valid asdf-resolvable Ruby pin

Replace the contents of `.ruby-version` with a bare version (NO `ruby-` prefix):
```
3.4.3
```

Create `.tool-versions` in the repo root. If the repo pins a Node version
elsewhere, include it; otherwise a Ruby-only file is fine for this plan:
```
ruby 3.4.3
```

**Verify**: `cat .ruby-version` → `3.4.3` (no prefix); `cat .tool-versions` →
`ruby 3.4.3`. Then from the repo root run `ruby -v` (no env prefix) →
`ruby 3.4.3...`. If asdf still resolves the wrong version, STOP — the shim/asdf
setup differs from what this plan assumes.

### Step 2: Bump the Docker base image

In `Dockerfile:1`, change:
```
ARG RUBY_VERSION=3.2.2
```
to:
```
ARG RUBY_VERSION=3.4.3
```
Leave the `FROM docker.io/library/ruby:$RUBY_VERSION-slim AS base` line as-is.

**Verify**: `grep -n "RUBY_VERSION" Dockerfile` → shows `ARG RUBY_VERSION=3.4.3`.
(Do not build the image as part of this step; the runtime suite is the gate.)

### Step 3: Reinstall gems on Ruby 3.4 and regenerate the lock as needed

Run `ASDF_RUBY_VERSION=3.4.3 bundle install`. Because `Gemfile.lock` has no
`RUBY VERSION` stanza, no lock edit is expected — but if bundler reports a
platform/version issue, run `ASDF_RUBY_VERSION=3.4.3 bundle install` again and
inspect the diff. Commit any `Gemfile.lock` change bundler makes on its own.

**Verify**: `ASDF_RUBY_VERSION=3.4.3 bundle install` → exit 0, "Bundle complete".
If any gem fails to **build** (native extension compile error) — the git-pinned
`administrate` beta and `pg`/`nokogiri` native gems are the likeliest — STOP and
report the exact gem and error (see STOP conditions).

### Step 4: Run the full suite and clear Ruby 3.4 deprecations

Run `ASDF_RUBY_VERSION=3.4.3 bin/rails test` and `:system`. Address any failure
or deprecation that is caused by the Ruby version and is a minimal, local fix.
Ruby 3.4 notable changes to watch for in output:
- `Hash#inspect` / frozen-string-literal formatting changes in assertions,
- deprecation of certain `URI`/`ostruct`/`csv` behaviors,
- changed `Kernel#Float`/`Integer` edge behavior.
Do NOT chase a failure into gem internals — that is a STOP condition.

**Verify**: `ASDF_RUBY_VERSION=3.4.3 bin/rails test` → 0 failures, 0 errors;
`ASDF_RUBY_VERSION=3.4.3 bin/rails test:system` → pass.

### Step 5: Confirm lint and the security warning cleared

**Verify**:
- `ASDF_RUBY_VERSION=3.4.3 bin/rubocop` → no offenses.
- `ASDF_RUBY_VERSION=3.4.3 bin/brakeman --no-pager` → the end-of-life Ruby
  warning is gone. (Grep the output: it must NOT contain a warning naming
  Ruby `3.2` / "end of life" / "EOL".)

### Step 6: Correct the setup doc only if needed

`docs/development_setup.md:35` already says `asdf install` reads `.tool-versions`
— which is now true because Step 1 created that file. No edit is required unless
you changed a developer-facing command. If you did, update the doc minimally.

**Verify**: `grep -n "tool-versions" docs/development_setup.md` → the reference
still matches reality (a `.tool-versions` file now exists).

## Test plan

- No new tests. The **entire existing suite** is the regression gate:
  `ASDF_RUBY_VERSION=3.4.3 bin/rails test` and
  `ASDF_RUBY_VERSION=3.4.3 bin/rails test:system` must both be green on 3.4.
- Structural pattern to preserve: the suite already runs under Minitest with
  factory_bot/webmock/mocha — do not change any test's expectations except a
  strictly-mechanical 3.4 formatting fix (and if one is needed, note it in the
  PR description).

## Done criteria

Machine-checkable. ALL must hold:

- [ ] `cat .ruby-version` prints `3.4.3` (or the chosen 3.4.x), with no `ruby-` prefix
- [ ] `.tool-versions` exists and contains `ruby 3.4.3` (or the chosen 3.4.x)
- [ ] `grep -n "RUBY_VERSION" Dockerfile` shows `3.4.3` (or the chosen 3.4.x)
- [ ] `ruby -v` from the repo root (no env prefix) reports `ruby 3.4.x`
- [ ] `ASDF_RUBY_VERSION=3.4.3 bin/rails test` exits 0 with 0 failures/errors
- [ ] `ASDF_RUBY_VERSION=3.4.3 bin/rails test:system` passes
- [ ] `ASDF_RUBY_VERSION=3.4.3 bin/rubocop` reports no offenses
- [ ] `ASDF_RUBY_VERSION=3.4.3 bin/brakeman --no-pager` no longer emits the EOL-Ruby warning
- [ ] No files outside the in-scope list are modified (`git status`)
- [ ] `plans/README.md` status row updated

## STOP conditions

Stop and report back (do not improvise) if:

- The `.ruby-version` / `Dockerfile` contents do not match the "Current state"
  excerpts (the codebase drifted since this plan was written).
- A gem fails to **build/install** on Ruby 3.4 — most likely the git-pinned
  `administrate` beta (`gem "administrate", github: ..., branch: "main"`) or a
  native gem (`pg`, `nokogiri`). Report the gem, version, and compiler error;
  do NOT unpin or bump gem constraints to force it (that widens scope and risks
  the admin UI).
- A test failure requires editing gem internals or changing more than a
  one-line application fix to resolve.
- `ruby -v` after Step 1 still does not report 3.4.x (asdf setup differs from
  the assumption that 3.4.3 is installed and resolvable).

## Maintenance notes

For the human/agent who owns this after the change lands:

- The Ruby version now lives in exactly two places: `.ruby-version` and
  `.tool-versions` (plus the `Dockerfile` ARG for the container). Keep all three
  in sync on the next bump. There is deliberately no `ruby` directive in the
  `Gemfile`.
- A reviewer should scrutinize: (1) any `Gemfile.lock` diff bundler produced,
  (2) any test-expectation edits made for 3.4 formatting changes, (3) that the
  brakeman EOL warning is actually gone (not just suppressed).
- Deferred out of this plan: bumping CI runner Ruby versions and rebuilding/
  publishing the Docker image — those live in the deploy pipeline, not here.
  Flag to the operator that CI config must be bumped separately.
