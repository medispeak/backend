# Template Playground — Design Spec

**Date:** 2026-08-16
**Status:** Approved (design). Implementation plan to follow.
**Repo:** `medispeak/backend` (this repo)
**Reference UX:** `ohcnetwork/care_filly_fe`, branch `medi` — the CARE EMR "Filly" scribe plugin

## 1. Goal

Let a logged-in tenant user open one of **their own templates** in the Rails app and run a
complete scribe round-trip from that page — press record, watch the transcript grow while
still talking, watch the template's own fields fill in one by one — **without integrating the
SDK, minting an API key, or leaving the app.**

Today a tenant can author a template, mint an API token, and read past sessions
(`config/routes.rb:34-46`). What they cannot do is find out whether their template actually
extracts anything until after they have integrated. The first-run experience is: spend ten
minutes authoring pages and fields, then leave to write code before learning it works.

**The playground is a fidelity instrument, not a debugging tool.** Its purpose is for the user
to *feel what their end users will feel*: real capture, real latency, real cost, real failure
modes. That decision (over "a template-author's iteration loop") drives every choice below.

**In scope:** one new page per template, a Devise-authenticated session/token seam, a Stimulus
recorder driving the public v2 API, live transcript, progressive field fill, and the result
rendered through the existing consultation partial.

**Out of scope for v1:** re-running a stored recording against edited fields/prompts. Segments
retain their audio (`ScribeTranscriptSegment has_one_attached :data`), so this stays cheap to
add later — it is deferred, not designed out.

## 2. Current system (ground truth)

Verified by reading `HEAD` (816d1f5) on 2026-08-16. Where `docs/` disagrees with code, code wins.

### 2.1 The v2 API already has every endpoint this needs

`config/routes.rb:60-77`, implemented in `app/controllers/api/v2/scribe_sessions_controller.rb`:

| Method & path | Purpose | Credential |
|---|---|---|
| `POST /api/v2/scribe_sessions` | Create session, declare `outputs` | **account token only** |
| `POST /api/v2/scribe_sessions/:id/tokens` | Mint scoped browser token | **account token only** |
| `POST /api/v2/scribe_sessions/:id/audio/segments` | `seq` + `segment`; per-segment ASR on arrival | either |
| `POST /api/v2/scribe_sessions/:id/commit` | Quota-gated, enqueues processing | either |
| `GET  /api/v2/scribe_sessions/:id` | Poll — `202` processing · `206` partial · `200` done **or failed** | either |

`before_action :require_account_token!, only: [:create, :index, :tokens]`
(`scribe_sessions_controller.rb:17`) is the single line that forces this design's shape: a
browser holding an `mss_` token can upload, commit, and poll, but can neither create a session
nor mint its own token.

### 2.2 The browser-credential seam is callable from Ruby

`app/services/scribe/session_token.rb` — `Scribe::SessionToken.mint(session, ttl:)` returns
`["mss_<MessageVerifier blob>", exp]`. Stateless, no DB row, `exp = min(15.minutes.from_now,
session.expires_at)`. It is a plain module, **not** gated behind the API, so a
Devise-authenticated controller can call it directly. `find_session`
(`scribe_sessions_controller.rb:560-572`) enforces `claims["sid"] == params[:id]`.

The token's `"scope" => ["audio","read"]` claim is **never checked** anywhere — only `sid` is.
Do not design assuming a narrower token can be minted.

### 2.3 Segments give a live transcript; chunks do not

Two independent upload streams exist:

- **`/audio/segments`** (`scribe_sessions_controller.rb:187-238`) — each part is an
  independently-decodable audio file, stored as a `ScribeTranscriptSegment` with
  `has_one_attached :data`, and transcribed **on arrival** by `TranscribeSegmentJob`
  (enqueued at `:231`). Exempt from the 25 MB storage cap. `ScribeSession#live_transcript`
  (`app/models/scribe_session.rb:93-102`) joins the `done` segments in `seq` order, and
  `ScribeSessionSerializer:51-59` surfaces it under the normal `transcript` key while the
  session is `uploading` or `processing`.
- **`/audio/chunks`** — durable storage only. `Scribe::AudioSource.yield_assembled`
  (`app/services/scribe/audio_source.rb:39-55`) **byte-concatenates** chunk bytes into one
  tempfile. Independently-headered parts (WAV, or restarted WebM) do not survive this.

The reference plugin uploads per-utterance WAVs to `/audio/chunks`
(`care_filly_fe/src/lib/medispeak-api.ts:148-166`) and therefore gets no live transcript.
**This design uses `/audio/segments` and is strictly better than the UX being copied on that
axis.**

### 2.4 Result rendering already exists

`app/views/scribe_sessions/_output.html.erb` renders one `ScribeOutput` as a label/value `<dl>`
with a scalar-normalizing lambda and a rose-tinted validation-errors block. Its object contract
is only `output_type, status, page, inline_fields, template_ref, result, result_errors,
transcript?, note?, status_pending?`. `app/helpers/ui_helper.rb` provides `status_badge`,
`format_cost`, `format_duration`, `format_tokens`, `friendly_time`.

### 2.5 Frontend reality

importmap-rails + propshaft. **No `package.json`, no bundler.** `config/importmap.rb` pins four
things plus `pin_all_from "app/javascript/controllers"`, which eager-loads — so a new
`playground_controller.js` auto-registers with zero wiring. Four Stimulus controllers exist;
**nothing in the repo touches `getUserMedia`, `MediaRecorder`, `fetch`, or polling.** This is
the first async code in the app.

Tailwind v3 via the standalone gem binary: `gray` remapped to zinc, `primary` = blue.
`@layer components` in `app/assets/stylesheets/application.tailwind.css` defines
`.btn/.btn-primary/.btn-white`, `.card/.card-pad/.card-header`, `.badge-*`, `.field-label`.
Class strings are only emitted if the literal appears in `app/views`, `app/javascript`,
`app/helpers`, or `app/assets/stylesheets` — **`app/controllers` is not scanned.**

The layout already wraps `yield` in `max-w-7xl mx-auto px-4 … py-8`; a new view must not add its
own container. Flash is `position: fixed z-50`; a sticky recorder must stay below `z-50`.

### 2.6 Constraints that shape the design

- **Rack::Attack throttles per account**, 120 rpm over a 60s window, and both credential types
  resolve to the same bucket (`config/initializers/rack_attack.rb`).
- **Segments settle all-or-nothing.** If any segment is not `done` at commit,
  `ensure_transcript!` raises and the session finalizes `failed` — no partial concatenation, no
  whole-file fallback (`app/services/scribe/orchestrator.rb:169-186`). The error names the
  unsettled seqs and appears only in `outputs[].errors` / `session.error`.
- **`GET /:id` returns 200 for `failed`** as well as `completed`. Check the `status` field.
- **Usage limits are checked only at commit** (`scribe_sessions_controller.rb:380-420`), which
  returns 402 `usage_limit_exceeded` / `insufficient_credit`. `TranscribeSegmentJob` meters per
  segment with no hold and no limit check, so a long recording bills as it goes and can then be
  refused at commit.
- **401 responses have an empty body** (`head :unauthorized`) — `JSON.parse` on every response
  throws on auth failure.
- **CSP is report-only today** (`config/initializers/content_security_policy.rb:32`) with
  `script_src :self`. Inline `<script>` works now and breaks later.
- `getUserMedia` requires a secure context. `allow_browser versions: :modern`
  (`application_controller.rb:8`) returns 406 to old browsers.
- **Development has no queue adapter** → ActiveJob falls back to `:async` in-process threads;
  jobs vanish on restart. Tests run `:inline`. Local behavior differs from prod.
- `docs/api/v2.md` is materially stale (no `/tokens`, `/chunks`, `/segments`, no top-level
  `transcript`, no `usage`). `test/integration/api/v2/` is the authoritative spec.

## 3. Locked decisions

| # | Area | Decision | Rejected alternative |
|---|---|---|---|
| D1 | Purpose | Faithful end-user experience | Template-author iteration loop (deferred, §1) |
| D2 | Auth | Hybrid: Devise controller for create + token; browser → `/api/v2` for upload/commit/poll | Internal controller proxying everything — duplicates upload logic, stops exercising the real API |
| D3 | Capture | Silero VAD (`@ricky0123/vad-web`) → one WAV per utterance | Web Audio → WAV (no deps but coarser boundaries); MediaRecorder restart (clips words at every seam) |
| D4 | Upload stream | `/audio/segments` | `/audio/chunks` (no live transcript, and byte-concatenation breaks per-utterance WAVs) |
| D5 | Page binding | Run **all** the template's pages as N `form` outputs in one session | A page picker — production posts all pages, so a picker is less faithful |
| D6 | Tagging | **None.** Playground runs are ordinary sessions, metered and visible in Consultations | An `origin` column + filtered list — rejected as unnecessary concept weight |
| D7 | Session creation | Extract `Scribe::SessionBuilder`, used by both the v2 controller and the playground | Constructing rows directly in the playground controller — guaranteed drift from API validation |
| D8 | Result rendering | Live states client-side; final result as a server-rendered `_output.html.erb` fragment injected in place | Reimplementing the partial in JS (drift); navigating to `/scribe_sessions/:id` (breaks the no-navigation UX) |

## 4. What we take from Filly, and what we leave

**Take:**

1. **Progress derived from real API signals, not a timer.** `FillyController.tsx:700` computes
   its step from whether a transcript exists yet. This maps 1:1 onto the poll payload and is the
   single best idea in the plugin.
2. **Transcript visible during processing**, in a collapsible scrollable card.
3. **Completion as a count** — "N fields filled" — with detail opt-in, and failure as a peer
   state with the same affordances, not an alert.
4. **Staggered field fill** with a highlight flash (`FIELD_FILL_DELAY_MS = 500`).
5. **Volume bars from an `AnalyserNode`** (fftSize 256, smoothing 0.75) and first-class
   pause/resume.
6. **`prefers-reduced-motion` disables every animation** in one block
   (`care_filly_fe/src/index.css:334-356`).

**Leave:**

- **The FAB** — fixed positioning, drag, per-user localStorage offset, viewport clamping
  (`src/lib/fab-position.ts`, ~300 lines). It exists because Filly is injected into someone
  else's page. We own this layout; the recorder is an inline region.
- **`src/lib/structured/*`** — SNOMED valuesets, medication dosage construction, facility-scoped
  service requests. Irrelevant: a medispeak `form` output is a flat scalar/enum object.
- **`template-builder.ts`** — Filly derives a schema at record time by walking the host
  questionnaire because it has no template. We *start* from a template; `page_id` resolves to
  real `FormField` rows and a real `page.prompt`.
- **Label-keyed results and fuzzy matching.** `Scribe::SchemaBuilder` keys form results by
  `FormField#title` exactly (`app/services/scribe/schema_builder.rb:34`). No matching needed.
- **The consent model** (facility flag + per-user preference + TnC dialog) and the admin quota
  CRUD pages. The app has `UsageLimit` + Pundit already.
- **The entire frontend stack.** React, module federation, shadcn/ui, Radix, Tailwind v4. Copy
  the *interaction*, not one line of the implementation.

## 5. Architecture

### 5.1 Routes

```ruby
resources :templates do
  get  "playground",                            to: "playground#show",           as: :playground
  post "playground/sessions",                   to: "playground#create_session", as: :playground_sessions
  post "playground/sessions/:session_id/token", to: "playground#mint_token",     as: :playground_session_token
  get  "playground/result",                     to: "playground#result",         as: :playground_result
end
```

All four nest under `/templates/:template_id/…` and resolve to a top-level
`PlaygroundController` (no `module:` scope — the app has no namespaced controllers outside
`Admin` and `Api::V2`).

`PlaygroundController < ApplicationController` — Devise-authenticated, Pundit-authorized.
Every action calls `authorize @template, :show?`, satisfying `verify_authorized`, which fires
on every non-index action **by string name** (`application_controller.rb:21-51`).

### 5.2 Session lifecycle

```
Browser                    Rails (Devise)                  /api/v2 (mss_ bearer)
   │                             │                                  │
   ├─ POST playground/sessions ─▶│                                  │
   │                             ├ Scribe::SessionBuilder.call      │
   │                             │   → ScribeSession                │
   │                             │   → 1 form ScribeOutput per Page │
   │                             ├ Scribe::SessionToken.mint        │
   │◀─ {session_id, token, exp} ─┤                                  │
   │                                                                │
   ├──────── POST /:id/audio/segments  (seq 0..n)  ────────────────▶│
   ├──────── GET  /:id            (every 2s, live transcript) ─────▶│
   ├──────── POST /:id/commit     (on stop) ───────────────────────▶│
   ├──────── GET  /:id            (every 750ms until terminal) ────▶│
   │                                                                │
   ├─ GET playground/result ────▶│ renders _output.html.erb fragment │
```

`Scribe::SessionBuilder` is extracted from `Api::V2::ScribeSessionsController#create`
(`:592-619`) preserving `validate_outputs` semantics verbatim, and takes
`(account:, user:, api_token: nil, mode:, modality:, language_hint:, outputs:)`. The v2
controller becomes a caller. This is the one production-code refactor in scope; it is justified
because the alternative guarantees the playground drifts from the API it exists to demonstrate.

`scribe_sessions.api_token_id` is nullable, so a token-less playground session is schema-legal.
**Consequence to accept:** with `api_token_id` NULL, idempotency is silently skipped
(`base_controller.rb:94`) and the `UNIQUE (api_token_id, dedupe_key)` index on `usage_events`
stops constraining, since Postgres permits unlimited NULLs. A retried pipeline could
double-write usage events for a playground session. Acceptable for v1 given D6; noted so it is
a known cost rather than a surprise.

### 5.3 Vendoring the VAD

```
bin/importmap pin @ricky0123/vad-web --download   # → vendor/javascript/
```

The `onnxruntime-web` wasm binaries and the Silero `.onnx` model go under `app/assets/`.
Propshaft digests filenames, so paths are passed into the controller as `data-` attributes via
`asset_path` — never hardcoded, never inline `<script>`.

Three consequences of D3, accepted:

1. **CSP gains `wasm-unsafe-eval` in `script_src`.** `script_src :self` alone blocks
   `WebAssembly.instantiate`. Report-only today, so nothing breaks until enforcement flips —
   but it must be added now or the feature dies at that flip. `wasm-unsafe-eval` is
   substantially narrower than `unsafe-eval`.
2. **`ort.env.wasm.numThreads = 1`, forced.** Multi-threaded onnxruntime needs
   `SharedArrayBuffer`, which needs COOP/COEP cross-origin isolation across the whole app.
   Not worth it for VAD.
3. **~10 MB of vendored assets**, so the VAD module is `import()`ed lazily on first press of
   record. The template page itself stays light.

### 5.4 The page

`app/views/playground/show.html.erb`, using `.card` / `.btn` (not the template builder's
competing indigo dialect):

- **Recorder region** — record/stop control, elapsed timer, five volume bars, pause/resume,
  and the derived processing step.
- **Transcript card** — collapsible, `max-h` scrollable, growing live.
- **Result region** — the template's pages and fields rendered as **empty rows waiting to
  fill**. This is the faithful analog of Filly's autofill: there is no host form here, so the
  template itself is the form that fills in. On completion the server-rendered fragment
  replaces it.

Entry point: a "Try it" `btn-primary` in the `templates/show` page-header actions block
(`app/views/templates/show.html.erb:3-14`), demoting "Edit template" to `btn-white`.

### 5.5 Capture and feedback

One `app/javascript/controllers/playground_controller.js`:

- On first record, `import()` the vendored VAD. Silero emits one utterance at a time →
  16 kHz mono WAV → `POST /audio/segments` with an incrementing `seq`.
- **Cap each utterance at ~20 s** so it stays under Sarvam's ~30 s REST ceiling
  (`app/services/llm/adapters/sarvam.rb:13-16`); Filly caps at 25 s for the same reason.
- An `AnalyserNode` off the same graph drives the volume bars.
- Poll `GET /:id` **every 2 s while recording**, 750 ms after commit. With VAD-paced segment
  uploads that is roughly 42 rpm against the 120 rpm per-account budget — deliberate, since
  Filly's 750 ms polling throughout would approach the limit on its own.
- Processing step: no transcript → *Transcribing*; transcript present → *Extracting details*;
  outputs terminal → *Filling form*.
- Fields populate on a 500 ms stagger with a highlight flash, all behind
  `prefers-reduced-motion`.

### 5.6 Result

On terminal status, `GET playground/result?session_id=…` returns a server-rendered fragment
using `_output.html.erb` verbatim, injected in place — no navigation. Surfaces the `usage` block
the serializer already returns (cost, tokens, audio seconds — `ScribeSessionSerializer:30-40`),
which is a genuine differentiator for someone evaluating the product. Links "View as
consultation" to `/scribe_sessions/:id`, which works because of D6.

## 6. Error handling

| Condition | Surface |
|---|---|
| Mic permission denied | Inline message + retry affordance; never a dead control |
| Insecure context / no `getUserMedia` | Explain HTTPS requirement, disable record |
| `402 usage_limit_exceeded` / `insufficient_credit` | Render the API's own message |
| `401` (token expired — indistinguishable from invalid, empty body) | Re-mint once via the Rails endpoint, retry; then fail visibly |
| Segment settle failure at commit | Show the unsettled seqs from `outputs[].errors`; offer **Retry**, which re-POSTs commit to retry exactly those segments |
| Provider failure | Session `status: "failed"` at HTTP 200 — render `outputs[].errors` |
| Poll timeout | Bounded attempts, then a failure state with a link to the consultation |

## 7. Testing

- **System test** (`test/system/`, currently empty; Capybara + headless Chrome already
  configured in `test/application_system_test_case.rb`). Drive the real flow with
  `--use-fake-device-for-media-capture --use-file-for-fake-audio-capture` and a fixture clip.
  This establishes the pattern for the repo.
- **Controller tests** for `create_session`, `mint_token`, and `result`, including the Pundit
  denial path for another account's template.
- **Unit tests** for `Scribe::SessionBuilder`, plus re-running the existing
  `test/integration/api/v2/` suite unchanged to prove the extraction is behavior-preserving.
- Note for implementers: dev runs ActiveJob `:async`, tests run `:inline`. Local timing will not
  match prod's Solid Queue (1 process × 3 threads).

## 8. Fixes folded in

Three defects this feature touches directly:

1. **`ScribeSessionPolicy` has no `create?`**, so it inherits `false` from `ApplicationPolicy`.
   Add one.
2. **`config/initializers/filter_parameter_logging.rb` filters `:audio` but not `:segment` or
   `:chunk`.** Latent today; this feature makes it live PHI in logs. Add both.
3. **The "never offer a new consultation" comments** in `app/views/dashboard/show.html.erb:95`
   and `app/views/scribe_sessions/index.html.erb:81` become false. Retire them deliberately and
   update the empty-state copy, which currently reads "Consultations appear here as soon as your
   application posts audio or a document to the API."

## 9. Known risks

- **Vendoring the VAD is the single riskiest step, and it is first.** `@ricky0123/vad-web`
  pulls in `onnxruntime-web`, which is large and uses dynamic imports; `bin/importmap pin
  … --download` resolves through JSPM and may not produce a working graph. **Fallback, to be
  taken without further design work if it fails:** pull the prebuilt ESM bundles, the
  `vad.worklet.bundle.min.js`, the `ort-wasm-simd*.wasm` binaries and `silero_vad*.onnx`
  straight from the npm tarballs into `vendor/javascript/` and `app/assets/`, and pin them by
  explicit path in `config/importmap.rb`. Attempt this step before writing any UI code, so a
  failure reshapes the work early rather than late.
- **Anthropic structuring is broken end-to-end.** `Llm::Adapters::Anthropic` returns
  `finish_reason: "tool_use"` for a successful forced tool call, but
  `StructuringStage::COMPLETE = %w[stop end_turn]` (`app/services/scribe/structuring_stage.rb:16`)
  raises on anything else. No test covers it. Only bites if an account's structuring assignment
  points at a Claude model — but the playground would be where a user discovers it. Out of scope
  to fix here; flagged so it is not misdiagnosed as a playground bug.
- **ASR cannot be assigned per Page or per Template** — both call sites omit `page:`
  (`orchestrator.rb:133`, `transcribe_segment_job.rb:29`), so resolution is Account → ancestors
  → System. `docs/architecture.md:25` implies otherwise and is wrong. The playground must not
  imply template-level ASR choice.
- **Concurrency.** Prod is Puma 3 threads + Solid Queue 1×3. Playground runs contend with real
  customer traffic for the same workers.
- **iOS Safari** MediaRecorder/container behavior is unverified. The VAD path produces WAV from
  raw PCM, which sidesteps container differences, but `getUserMedia` constraints and AudioWorklet
  support on iOS need an empirical check during implementation.
