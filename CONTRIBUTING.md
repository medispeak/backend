# Contributing to Medispeak Backend

Thanks for your interest in contributing. This is the Rails 8 API behind
Medispeak — a multi-tenant, model-agnostic clinical scribe. Because it handles
protected health information (PHI) for real tenants, we hold a high bar on
tests, tenant isolation, and not leaking data into logs, fixtures, or issues.

By participating you agree to our [Code of Conduct](CODE_OF_CONDUCT.md).
Found a security issue? Do **not** open an issue — follow
[SECURITY.md](SECURITY.md).

## Prerequisites

- **Ruby 3.4.1** — pinned in [`.ruby-version`](.ruby-version) and
  [`.tool-versions`](.tool-versions). Use `asdf install` from the project root
  and you'll get the right one.
- **PostgreSQL** — the only supported database. Active Record, Solid Queue,
  Solid Cache, and Solid Cable all run on it.
- **libvips** — required by Active Storage for attachment processing.
- Optionally **Docker** + **Docker Compose** if you'd rather not install
  Postgres locally.

## Local setup

Don't follow a summary here — the real instructions are maintained in:

- [`docs/development_setup.md`](docs/development_setup.md) — native setup on
  macOS, Ubuntu, and WSL: dependencies, Postgres credentials, `.env` from
  `example.env`, `rails db:setup`, and `bin/dev`.
- [`docs/docker_setup_guide.md`](docs/docker_setup_guide.md) — the containerized
  path via `docker-compose.yml`.

Seeding creates a demo admin account; the credentials are in the setup doc.

## Running the tests

The suite is Minitest, with `factory_bot`, `webmock` (all provider HTTP is
stubbed), and `mocha`.

```bash
bin/rails db:test:prepare      # once, and after any migration
bin/rails test                 # unit, model, job, service, controller, integration
bin/rails test:system          # Capybara + headless Chrome
```

Narrow it down while iterating:

```bash
bin/rails test test/services/scribe/orchestrator_test.rb
bin/rails test test/services/scribe/orchestrator_test.rb:42
```

Notes:

- System tests drive a real headless Chrome and, for the recording flows, a real
  audio device. Some of them are skipped on CI for that reason — run them
  locally before touching anything in the recording path.
- Never point tests at a live model provider. Stub the HTTP with `webmock`; the
  adapter contract tests exist to keep that honest.
- If you work in a git worktree, note that all checkouts share the same
  `medispeak_test` database by default. Export a per-branch `DB_NAME_TEST` to
  avoid the two checkouts fighting over the schema.

## Running the checks CI runs

CI ([`.github/workflows/ci.yml`](.github/workflows/ci.yml)) runs five jobs. Run
all of them locally before you push and you'll almost never see a red PR:

```bash
bin/rubocop                            # lint (CI runs it with -f github)
bin/brakeman --no-pager                # Rails static security analysis
bundle exec bundle-audit check --update # known CVEs in the gem dependency tree
bin/importmap audit                    # known CVEs in pinned JavaScript
bin/rails db:test:prepare test test:system
```

If `bundle-audit` flags an advisory that genuinely isn't reachable here, it goes
in [`.bundler-audit.yml`](.bundler-audit.yml) **with a written justification and
the upgrade that would actually resolve it** — never as a bare ignore.

## Code style

- RuboCop with [`rubocop-rails-omakase`](https://github.com/rails/rubocop-rails-omakase)
  — Rails' own house style, configured in [`.rubocop.yml`](.rubocop.yml). Don't
  add per-cop overrides without a reason in a comment.
- `bin/rubocop -a` autocorrects most offences. Run it before pushing.
- Comments should carry the non-obvious **why**, in a line or two. Skip comments
  that restate the code.
- Prefer the Rails way: fat models, thin controllers, and service objects that
  return result/error values rather than raising for expected failures (see
  `Scribe::SessionBuilder` for the pattern).

## Project layout

The interesting seams live under `app/services/`, and they exist so the HTTP
layer never names a model or a price:

| Path | What it owns |
|------|--------------|
| `app/services/llm/` | The provider abstraction. `Llm::Config` + `Llm::ConfigResolver` resolve which model handles a function (`asr` / `structuring` / `ocr`) by cascading Page → Template → Account → ancestor accounts → System → ENV. `Llm::Caller` is the single owner of fallback. `Llm::Registry` maps a provider kind to an adapter in `adapters/` (`OpenaiCompatible`, `Anthropic`, `Sarvam`), each of which normalizes results into `Llm::Result` / `Llm::Usage` and maps transport failures onto the `Llm::Error` hierarchy. |
| `app/services/scribe/` | The pipeline for one session. `Scribe::Orchestrator` extracts the transcript **once** (segment assembly, whole-file ASR, or document OCR by modality), then runs each output independently and rolls up the status. Around it sit `AsrStage`, `OcrStage`, `StructuringStage`, `SchemaBuilder`, `SchemaValidator`, and `WebhookSigner`. |
| `app/services/metering/` | Usage and money. `Metering::UsageRecorder` writes exactly one dedupe-keyed `UsageEvent` per physical provider attempt, priced by `Metering::PriceBook`; `QuotaGuard` holds/deducts/refunds against the credit ledger and `LimitGuard` is the pure-read admission gate for `UsageLimit` caps. |

Read [`docs/architecture.md`](docs/architecture.md) before changing any of the
above — it documents the invariants (one usage event per attempt, extraction
runs once, metering can never demote a finalized output, jobs don't re-raise)
that the tests are there to protect. [`docs/api/v2.md`](docs/api/v2.md) and
[`docs/configuration.md`](docs/configuration.md) cover the public surface and
runtime model configuration.

Adding a provider? Implement an `Llm::Adapter` subclass, register it in
`Llm::Registry`, and add contract tests alongside the existing adapter tests.
You should not need to touch the orchestrator.

## Branch and PR workflow

1. Fork (or branch, if you have push access) off `main`. Name the branch for the
   change: `fix/segment-dedupe-key`, `feat/ocr-page-caps`.
2. Keep the change focused. Refactors that ride along with a behaviour change
   make review much harder — split them.
3. Add or update tests. A bug fix should come with a test that fails without it.
4. Migrations: check in the updated `db/schema.rb`, and make them safe to run
   against a live database (no long-held locks, no destructive change without a
   deprecation step).
5. Run the CI checks above.
6. Open a PR against `main` and fill in the template. Link the issue it closes.
7. **PRs must keep CI green.** A red pipeline won't be merged; if CI fails for a
   reason you believe is unrelated, say so in the PR rather than re-running and
   hoping.
8. Address review feedback with follow-up commits (we squash on merge, so no
   need to rewrite history mid-review).

Dependabot opens daily dependency PRs. Feel free to help triage them.

## Commit messages

- Imperative mood, present tense: `Add retry API for failed transcription`, not
  `Added…` / `Adds…`.
- One logical change per commit. Keep the subject under ~72 characters.
- Use the body to explain **why**, and note anything operationally relevant
  (backfills, ENV vars, provider spend implications).
- Reference issues with `Fixes #123` / `Refs #123`.
- PR titles follow the same rules and end with the PR number on merge — that
  merged title is what lands in the `main` history.

## Data handling

This is the non-negotiable part.

- **Never** commit real patient data, audio, transcripts, or lab reports — not
  as fixtures, not in tests, not in a screenshot attached to a PR.
- **Never** commit API keys, tokens (`msk_live_…`), or provider credentials.
  Config belongs in `.env` (gitignored) and in the database at runtime.
- Don't add PHI to log lines, error messages, exception payloads, or webhook
  bodies. Webhooks are deliberately PHI-light: ids, statuses, timestamps.
- Anything that reads or writes tenant-scoped data must be scoped to the account
  and covered by a test proving another tenant can't reach it.
