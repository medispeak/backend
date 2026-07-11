# Plan 024: Pre-fill the form DURING recording (live form-fill) so the structured output is ready the instant the clinician stops

> **Status: SHIPPED (backend), flag-gated OFF.** This is a decision + design
> record for a capability already built and tested, not an executor plan. The
> FE/SDK wiring is deferred pending the cost decision below.

## Status

- **Priority**: P1 (the core "world's fastest text -> form filling" lever)
- **Effort**: M (backend done; SDK+FE deferred)
- **Risk**: LOW (backend), MED (FE — needs an SDK publish)
- **Depends on**: plans/022 (incremental segments feed the live transcript)
- **Category**: perf / product
- **Built at**: 2026-07-11, on top of commit `78bd27d`.

## Why this matters

The genuine "fastest form fill" is not a faster call at stop — it is *no call
at stop*, because the form was already filled while the clinician was still
talking. Plan 022 already exposes a growing `live_transcript` during recording
(the done segments' texts, in order). This plan structures that growing
transcript into the session's form outputs continuously, so by the time the
clinician stops, the form is (almost) fully pre-filled and only the final few
seconds of speech need a last structuring pass.

Measured today (incremental path, US->blr): stop -> filled form ≈ 5.2s, of
which ~1.4s is structuring (gpt-4.1-mini) and the rest is last-segment ASR +
commit round-trip + Solid Queue pickup + client poll granularity. Live
form-fill collapses the *perceived* fill to ~instant: the form visibly fills as
the clinician speaks; the commit pass only refines it.

## The cost trade-off (why it is OFF by default)

Each live pass is a real provider structuring call per form output. A 2-minute
recording polled every ~4s is ~30 gpt-4.1-mini calls (~$0.002/session on top of
the single committed call). Cheap, but non-zero and per-session — a real
product/billing decision, not a free win. So it ships behind a flag and is OFF
until explicitly enabled.

Interim passes are **not persisted and not metered** — they are a speculative
UX assist. The authoritative, metered structuring still happens exactly once at
commit (`Scribe::Orchestrator`). medispeak absorbs the small interim provider
cost when the flag is on. (If we later want to bill it, meter each pass in
`Scribe::LiveStructurer` — deliberately left out for now.)

## What shipped (backend)

- `Scribe::Incremental.live_form_enabled?` — `SCRIBE_INCREMENTAL_ASR=true &&
  SCRIBE_LIVE_FORM=true`. Requires the incremental path (no segments -> no live
  transcript to structure).
- `Scribe::LiveStructurer` (`app/services/scribe/live_structurer.rb`) —
  structures a transcript string into every `form` output of a session via the
  same `Llm::ConfigResolver` + `Scribe::StructuringStage` seam as commit, and
  returns the merged `{ key => value }`. Best-effort: a failed pass never breaks
  recording; the commit fill is authoritative.
- `GET /api/v2/scribe_sessions/:id/live_form` — returns
  `{ structured_data: {...} }`. When the flag is OFF it returns `{}` (200, not
  404) so a polling client degrades to "no pre-fill" instead of erroring. Reads
  the session's `live_transcript` (blank -> `{}`, no provider call). Auth is the
  same session/account credential as the other read routes; a foreign token
  404s.
- Tests: `test/integration/api/v2/live_form_test.rb` (structures during
  recording; empty before any segment; empty + no provider call when flag off;
  foreign-token 404).

## What is deferred (FE + SDK) — needs the cost decision + an npm publish

To make the form visibly fill during recording:

1. SDK: add a `liveForm?: boolean` record option and a poll loop that
   `GET`s `:id/live_form` on `liveFormPollIntervalMs` (default ~2500ms — coarser
   than the transcript poll, since each hit is a provider call), emitting a
   `partialForm` event with the merged `structured_data`. OFF by default.
   *(Requires the user to publish a new `@medispeak/scribe-ts-sdk` — I cannot
   publish to npm.)*
2. FE (`care-medispeak-fe`): on `partialForm`, progressively populate the form
   fields (same merge the commit result uses). Behind the same OFF-by-default
   option so no wasted requests until enabled.

## How to enable (when the cost is accepted)

1. Backend env: `SCRIBE_INCREMENTAL_ASR=true`, `SCRIBE_LIVE_FORM=true`
   (DO App Platform: web + worker). No deploy needed — env-only.
2. Publish the SDK with the `liveForm` option; bump the FE to it; pass
   `liveForm: true` (+ a poll interval) into `record(...)`.
3. A/B: compare perceived stop->fill with the flag on vs. off; watch the extra
   structuring cost per session in the usage dashboard.

## STOP conditions

- If enabling ever changes the *committed* output (it must not — the commit pass
  is independent and authoritative), stop and investigate.
- If live passes show in metered usage (they must not be metered), stop.
