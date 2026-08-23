## Summary

<!-- One or two sentences: what does this PR do? -->

Fixes #

## What changed and why

<!--
The reasoning, not a file list — the diff already shows what changed.
Call out anything reviewers should look at hardest, and anything that touches
tenant scoping, PHI, provider spend, or the credit ledger.
-->

## How it was tested

<!-- Which tests you added or updated, and anything you verified by hand. -->

Checks run locally:

- [ ] `bin/rails test`
- [ ] `bin/rails test:system`
- [ ] `bin/rubocop`
- [ ] `bin/brakeman --no-pager`
- [ ] `bundle exec bundle-audit check --update`
- [ ] `bin/importmap audit`

## Checklist

- [ ] **No secrets or PHI in the diff** — no API keys, tokens (`msk_live_…`),
      provider credentials, patient data, real transcripts, audio, or lab reports
      in code, tests, fixtures, or screenshots.
- [ ] Tests cover the change; a bug fix has a test that fails without it.
- [ ] Tenant-scoped reads and writes stay scoped to the account, with a test
      proving another tenant can't reach them.
- [ ] No PHI added to log lines, error messages, exception payloads, or webhook
      bodies.
- [ ] Provider HTTP is stubbed (`webmock`) — no live model calls in tests.
- [ ] Migrations include the updated `db/schema.rb` and are safe against a live
      database.
- [ ] Docs updated if behaviour, the v2 API, configuration, or metering changed
      (`docs/`, `README.md`).
- [ ] CI is green.
