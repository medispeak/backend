# Plan 025: Latency frontier audit — where "stop → form ready" time goes, and the real next wins

> **Status: FINDINGS (verified).** Output of an adversarial multi-agent audit
> (5 latency lenses × find → refute) of the scribe stop→fill path, run against
> HEAD `2828e07` on 2026-07-11. Every candidate below was independently
> verified against the source; the buckets reflect what survived refutation.
> No code is changed by this doc — it is the map + the prioritized decisions.

## The measured path (default whole-file path, 1 form output, US client → India backend)

| ms | step | file |
|---:|------|------|
| 150 | POST /commit in-flight (½ of ~300ms RTT) | scribe_sessions_controller.rb |
| 60 | commit guards + QuotaGuard.hold! + status→processing + enqueue + 202 | scribe_sessions_controller.rb |
| 50 | Solid Queue worker claims the job (polling_interval 0.1s → ~50ms avg) | config/queue.yml |
| 5 | job: find_by + (redundant) status→processing | process_scribe_session_job.rb |
| 150 | ensure_transcript!: blob download + ffprobe (whole-file path) | orchestrator.rb |
| **2000** | **ASR (Whisper, overhead-bound single call)** | openai_compatible.rb |
| 15 | persist transcript + best-effort meter(:asr) | orchestrator.rb |
| 10 | structuring setup: fields/prompt + ConfigResolver + SchemaBuilder | orchestrator.rb |
| **1400** | **Structuring (gpt-4.1-mini, strict json_schema)** | openai_compatible.rb |
| 20 | validate/repair (in-memory; +1400ms only if a repair round-trip fires) | structuring_stage.rb |
| 5 | finalize_session_status! → **form data durably ready here** | orchestrator.rb |
| **800** | **client poll tail**: ~500ms poll-interval quantization + ~300ms RTT | scribe_session_serializer.rb |
| **≈4665** | **total** | |

**73% of the time is the two provider calls** (ASR 2000 + structuring 1400).
The client poll tail is another 17%. Everything server-side that isn't a
provider call — commit, queue pickup, all DB writes, serialization — is <100ms
combined. There is no fat to trim in our own code; the time is in (a) the model
calls and (b) how the client observes the result.

## The biggest win is already ON in prod; the second is built and waiting

1. **`SCRIBE_INCREMENTAL_ASR=true` — ALREADY ENABLED on prod** (top-level env,
   reaches both web + worker; verified 2026-07-11). Removes the ~2000ms ASR call
   + ~150ms blob download from the stop→fill path — each segment is transcribed
   on arrival, so commit just concatenates (~20-50ms). **Prod already runs the
   ~2500ms path, not 4665ms**, and structuring is the dominant term today. (So
   the whole-file table above is the *counterfactual* — the path if this flag
   were off. Worst case with the flag on: a still-in-flight trailing segment
   reintroduces one ~2000ms inline ASR or up to a 15s `wait_for_segment` poll.)
2. **`SCRIBE_LIVE_FORM=true`** (plan 024, shipped, flag off, needs an SDK
   publish + FE wiring). Structures the transcript *during* recording, so the
   form is pre-filled the instant the clinician stops — perceived fill ≈ instant.
   Removes the *remaining* dominant ~1400ms from perceived latency. Costs
   ~$0.002/session of extra structuring calls (the cost decision).

Since #1 is already on, the live path is ~2500ms and **structuring (~1400ms) +
the client poll tail (~800ms) are now the whole game** — which is exactly what
the live-form-fill flag (#2) and the long-poll (below) target.

## Verified next wins that need a decision (NOT shipped autonomously)

Ranked by value. All are "free" (zero extra provider $) unless noted.

1. **Bounded server-side long-poll on `GET /:id`** — hold a non-terminal read
   open up to ~2-3s, re-checking `status` every ~100-150ms (reload only the
   status column; check the AR connection back in between sleeps), return the
   instant it goes terminal. Reclaims the ~400-500ms poll-quantization tail with
   a **byte-identical client contract (no SDK/FE change)**. *Blocker:* Puma pins
   3 threads (config/puma.rb), so a held poll is ~33% of web capacity; needs a
   capacity bump (WEB_CONCURRENCY / threads) + a connection-checkin guard first.
   **Best win that needs no client change.**
2. **Inline structuring in `/commit` for the incremental all-segments-done
   path** — return the completed session in the commit `200` and skip the
   202+poll entirely. ~850ms (queue pickup + full poll tail). *Blockers:* makes
   the commit request block on the LLM (needs Puma headroom + an airtight
   all-done guard so `wait_for_segment`/whole-file ASR can never run in-request),
   AND a client change (read the structured data from the commit response
   instead of polling). Biggest single number, most moving parts.
3. **Parallelize the N structuring calls for multi-output sessions**
   (orchestrator.rb:50-61 runs them sequentially → N×1400ms). Turns a 3-form
   session's ~4200ms of structuring into ~1400ms. Free, backend-only. *Blocker:*
   a core-pipeline concurrency change — thread-safety + DB connection-pool
   handling (safe pattern: parallelize only the IO-bound LLM calls, hold no DB
   connection across them, persist/meter sequentially after) — and it only helps
   multi-output sessions. Wants careful implementation + tests + review, not a
   blind autonomous ship.
4. **Keep-alive HTTP connection to the provider** (openai_compatible.rb rebuilds
   the client per call; ruby-openai 6.5.0 does `Faraday.new` per request).
   Small, and only on a remote provider host. *Blocker:* needs a new gem
   (net-http-persistent) + an override of ruby-openai's per-request `conn`, plus
   stale-socket/thread-safety load-testing in the threaded worker.

## Verified NOT worth it (negligible / off the user-perceived path)

All confirmed real but sub-perceptible, and all in the background job (the web
request already returned 202), so **zero user-facing latency**:

- Queue worker `polling_interval` 0.1→0.05: ~25ms avg, stochastic (0-50ms),
  ~0.5% of the pipeline, permanent 2× empty-poll SELECT rate. Two reviewers
  split "small" vs "negligible". Fold into a config pass if ever; not a
  standalone win.
- Drop the redundant `status→:processing` write in the job (~1-5ms, background).
- Preload `page: :form_fields` for the output loop (sub-ms N+1, background).
- Memoize the Account/System ConfigResolver lookups (sub-ms, background).
- ffprobe in `commit_estimate`: relocating it changes the `insufficient_credit`
  pre-flight gate's conservativeness for single-shot uploads (metering-gate
  judgment call), and only affects 202-ack timing, not form-ready latency.
- Decode params (temperature 0 / seed), context-out-of-schema, non-strict
  schema: all **behavior changes** to a clinical extraction model — measure-first
  experiments, never blind ships.

## Bottom line

Our own code is already lean: <100ms of the pipeline is us; the rest is the two
model calls and the client's observation of the result. Incremental ASR (the
~2000ms win) is already on in prod, so the live path is ~2500ms and the only
remaining levers are: **live-form-fill** (removes the perceived ~1400ms
structuring wait — built, needs the cost decision + SDK publish), the
**bounded long-poll** (removes ~500ms poll tail, no client change, needs Puma
capacity), and **parallel structuring** (only for multi-output sessions). There
is no further safe, free, perceptible, backend-only win to ship blind — the next
step is a product/capacity decision, not more code.
