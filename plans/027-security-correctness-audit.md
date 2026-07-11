# Plan 027: Security + correctness audit of the recently shipped code (findings + resolutions)

> **Status: FIXED (most) / DEFERRED (2) / REJECTED (audit noise).** Unlike an
> executor plan, this is a resolution record: a fresh `/improve`-style audit
> (6 lenses × find → adversarial-verify, 38 agents) over the code shipped this
> week (Sarvam, realtime, live-form, incremental ASR, metering). Run against
> HEAD `cc619e9`, fixed in `259d18e`, 2026-07-12.

## Fixed

### CRITICAL — clinical data loss
- **Segment orphaned in `transcribing` silently dropped from the transcript**
  (`orchestrator.rb`). A segment neither `done` nor `failed` at commit (worker
  killed mid-provider-call, or an async job slower than the 15s inline wait) was
  omitted from the concatenated transcript while the session finalized
  `completed` — a clinical note generated from a transcript missing part of the
  consultation, no error surfaced. **Fix:** assemble only when ALL segments are
  `done`; any unsettled segment routes to a whole-file fallback for full
  coverage; `finish_incomplete_segments!` also waits when `perform_now` loses the
  atomic claim to an async job. Metered once only when nothing else was billed.
  Regression tests in `orchestrator_segments_test.rb`.

### HIGH
- **Session (`mss_`) tokens bypassed all rate limiting** (`rack_attack.rb`). They
  aren't `ApiToken` rows, so the discriminator resolved `nil` and skipped
  throttling — leaving `realtime_token` / `live_form` / `audio/segments` an
  unthrottled, operator-billed cost channel. **Fix:** resolve session tokens to
  their account (`session_token_account_id`) so they share the per-account rpm.
- **Realtime + live-form ran on the operator key with no credit gate.** **Fix:**
  `QuotaGuard.affordable?` gates both — realtime blocks balance ≤ 0 (a floor),
  live-form blocks a negative balance. (Full per-session realtime metering
  stays deferred — the browser streams directly; see plan 026.)
- **Commit was check-then-act** — racing commits both enqueued the pipeline,
  creating duplicate `Transcript` rows. **Fix:** an atomic conditional UPDATE
  claims the commit; losers 409; a failed quota hold rolls the claim back.
- **Cross-tenant `page_id` on v2 create** — a tenant could name another
  account's page and have the pipeline read its form schema / prompt / model.
  **Fix:** scope to the caller's own + legacy-shared (`account_id NULL`) pages,
  with a non-oracle error message.

### MEDIUM
- **POST `/audio` reset status to `uploading` unconditionally**, un-terminating a
  completed session and reopening the commit gate. **Fix:** reject unless
  `created`/`uploading`; set status only from `created`.
- **Incremental kill-switch double-charged ASR** (metered segments + metered
  whole-file). **Fix:** whole-file meters only when no segment was billed.
- **Missing `seq`/`chunk`/`segment` params 500'd.** **Fix:** base controller
  rescues `ActionController::ParameterMissing` → 422.
- **Single-shot `/audio` had no per-session byte cap.** **Fix:** enforce the
  running total against `MAX_AUDIO_BYTES`.

### LOW
- Realtime guards on an `api.openai.com` host, not just provider kind (OpenRouter
  shares the kind). Sarvam non-JSON 200 → `BadResponse` (was `TypeError`).
  `ProcessScribeSessionJob` no longer demotes an already-completed session to
  `failed` on a late error; webhook enqueue is isolated. Live-form flag comment
  corrected to "unmetered".

## Deferred (documented, low value / larger change)

- **`AudioDuration.estimated` never reaches `UsageEvent.estimated`** — byte-guessed
  ASR durations are recorded as exact. Labeling only (not the charge amount);
  threading the flag touches the hot ASR path in both adapters. Worth doing in a
  dedicated metering-accuracy pass.
- **`live_form` does synchronous LLM calls inside the 3-thread Puma pool** (up to
  the provider timeout). Real, but `live_form` is OFF by default and now
  credit-gated; when enabling it broadly, make it async or cap the live-pass
  timeout (also relevant to the plan 025 long-poll capacity note).
- **Migration key backfill runs once** — a Sarvam provider created before
  `SARVAM_API_KEY` was set would keep a NULL key. Handled operationally (the key
  was a SECRET before the deploy that ran the migration); a boot-time backfill
  would make it self-healing.

## Rejected (audit over-report / already fixed)
- "Caller fallback re-sends a consumed audio IO (0-byte upload)" ×2 — **already
  fixed** in `cc619e9` before this audit's verify wave saw it.
- "v2 401 responses are bodyless" — `head :unauthorized` is the intended
  pre-auth contract; not a regression.
- "Repo-hygiene drift (untracked plans, `.agents/`)" — **already fixed** in
  `2cdff22`.
