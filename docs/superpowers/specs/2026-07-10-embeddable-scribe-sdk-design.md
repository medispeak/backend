# Embeddable Scribe SDK — Design Spec

**Date:** 2026-07-10
**Status:** Approved (design). Backend-first; SDK next; FE adoption deferred.
**Repos:** `medispeak/backend` (this repo), `@medispeak/scribe-ts-sdk` (new), a Care EMR scribe frontend plugin (later)

## 1. Goal

Make Medispeak's scribe a **drop-in capability for any browser application**: a clean,
Medispeak-native TypeScript SDK, backed by new browser-facing backend capabilities, so
an app can record a consultation and auto-fill a form without pre-provisioning anything
and without ever holding an account secret in the browser.

The proving consumer is a **Care EMR voice-scribe frontend plugin** that today is coupled to
a third-party (incumbent) scribe SDK. It cannot use Medispeak as-is: the coupling is at the
SDK/source level, the incumbent wire protocol differs (session `txn_id`, chunked streaming,
template CRUD, provider-specific result shapes), auth is a long-lived vendor JWT rather than
Medispeak's `msk_live_` bearer, and structured extraction targets template CRUD rather than a
stored `page_id`. This spec builds the capability that lets that plugin — and any future app —
adopt Medispeak with a small, well-defined integration surface.

**In scope:** three backend capabilities (scoped session tokens, native chunked/resumable
upload, inline form schema) plus browser CORS, and the design contract for the SDK.
**Deferred (own spec, once the SDK exists):** migrating the reference Care plugin off the
incumbent SDK.

## 2. Current system (ground truth)

The async, metered **v2 API** (`app/controllers/api/v2/`) already exists:

| Method & path | Purpose |
|---|---|
| `POST /api/v2/scribe_sessions` | Create session; `outputs:[{type}]`, `language_hint`, `mode`, `callback_url`. |
| `POST /api/v2/scribe_sessions/:id/audio` | Attach audio — **one multipart file**; content-type + 25 MB validated. |
| `POST /api/v2/scribe_sessions/:id/commit` | Billable, quota-gated, idempotent; enqueues `ProcessScribeSessionJob`. |
| `GET  /api/v2/scribe_sessions/:id` | Poll: `200` done · `202` processing · `206` partial. |
| `GET  /api/v2/config`, `GET /api/v2/usage` | Discovery + usage rollups. |

- **Auth:** `Authorization: Bearer msk_live_…` → `ApiToken.authenticate` (SHA-256 digest,
  active + not-expired), `current_account` scoping. Account-level secret.
- **Session model** (`app/models/scribe_session.rb`): `has_many_attached :audio_files`,
  `status` (`created/uploading/processing/completed/partial/failed/expired`),
  `expires_at` (24 h), `callback_url` (SSRF-validated), `idempotency_key`.
- **Outputs** (`scribe_outputs`): `output_type ∈ {transcript, form, note}`. A `form`
  output **requires a stored `page_id`** (`validate_outputs` calls `Page.exists?`);
  `Scribe::SchemaBuilder` turns a Page's `FormField`s into the core JSON schema (the
  single source of truth), and `Scribe::Orchestrator` runs ASR once then structures each
  output. `SchemaBuilder` already handles the **5 field types**: `string`, `number`,
  `boolean`, `single_select` (enum), `multi_select` (array of enum).
- **CORS** (`config/initializers/cors.rb`): currently `origins "*"` for all resources
  (flagged SEC-08 in the prior audit; this spec scopes it).

**What's missing for browser embedding:** (a) any way to authorize a browser without the
account secret; (b) chunked/resumable upload (single multipart only; the model-agnostic
spec §7 reserved chunked `:seq` for later); (c) any way to extract against an **ad-hoc**
form the caller supplies at runtime (only stored Pages today).

## 3. Locked decisions

| Area | Decision |
|---|---|
| SDK surface | **Clean Medispeak-native SDK.** No mimicry of any incumbent SDK. The reference FE adapts its ~2 integration files (deferred). |
| Browser auth | **Short-lived, session-scoped tokens** minted server-side by the app's backend from its `msk_live_` token. The SDK is `tokenProvider`-based and never sees the account secret. |
| Upload | **Native chunked + resumable** through Medispeak; backend reassembles chunks into the session's audio blob (storage-agnostic: Disk/MinIO/S3). Presigned-S3-direct is explicitly out of scope for now. |
| Inline schema | The `form` output accepts an **inline `fields` array** (5 native field types) as an alternative to a stored `page_id`. Results come back keyed by the caller's field `key`. |
| Sequencing | **Backend → SDK → FE.** Each phase independently shippable. FE migration is a later, separate spec. |

## 4. Architecture

```
App backend (holds msk_live_)                 Browser (SDK, no account secret)
  │  POST /scribe_sessions  (create, inline fields)   ────────────────► 201 {id}
  │  POST /scribe_sessions/:id/tokens  (mint scoped)  ────────────────► {session_token, exp}
  │                                                                        │
  │           hands session_token to the browser  ◄───────────────────────┘
  ▼
Browser SDK  ──Bearer <session_token>──►  Api::V2 (session-scoped auth)
  POST /:id/audio/chunks  (seq, blob)      ← streamed during recording, idempotent per seq
  GET  /:id/audio/status  (received seqs)  ← resume after a drop
  POST /:id/commit                          → reassemble chunks → ProcessScribeSessionJob
  GET  /:id                                 → poll 202/200/206 → {outputs:[{type,status,result}]}
```

The account secret stays server-to-server. The browser holds only a session-scoped token
for `audio/chunks`, `audio/status`, `commit`, and `GET :id` **of its own session**.

## 5. Backend capabilities

### 5.1 Scoped session tokens

A **stateless, signed** token — no new table.

- **Minting:** `POST /api/v2/scribe_sessions/:id/tokens`, authed with the account
  `msk_live_` token (account must own the session). Returns
  `{ token: "mss_…", expires_at }`. The token payload is
  `{ sid: <session_id>, scope: ["audio", "read"], exp }` signed with a
  `Rails.application.message_verifier(:scribe_session)` (purpose-scoped, TTL ≤ the session's
  `expires_at`, default a few minutes, refreshable by re-minting).
- **Verification:** a `before_action` in `Api::V2::BaseController` resolves auth in this
  order: (1) a valid `msk_live_` account token → full v2 access as today; (2) else a valid
  signed session token → access **only** to that `sid`'s `audio/chunks`, `audio/status`,
  `commit`, and `show` routes, and only while unexpired. A session token presented for any
  other session id, any account-wide route (`create`, `index`, `config`, `usage`, `tokens`),
  or after expiry → `401`.
- **Why signed, not a DB row:** verification is stateless (no lookup, no write on the hot
  upload path), revocation rides on the short TTL + the session's own `expired?`/status.

### 5.2 Native chunked + resumable upload

New routes on the `scribe_sessions` member, beside the existing single-shot `POST /:id/audio`
(kept for simple/server clients):

| Method & path | Body / result |
|---|---|
| `POST /api/v2/scribe_sessions/:id/audio/chunks` | `seq` (int ≥ 0), binary `chunk`, optional `final: true`. **Idempotent per `seq`** — re-POSTing a seq overwrites/no-ops. `200 {received: seq}`. |
| `GET  /api/v2/scribe_sessions/:id/audio/status` | `{ received_seqs: [...], final_seen: bool, bytes: N }` — lets the SDK resume by sending only missing seqs. |

- **Storage:** each chunk is persisted via ActiveStorage (a per-`(session, seq)` blob, or an
  appended part), so it works on Disk (dev/test), MinIO, and S3 unchanged.
- **Size/type guards:** per-chunk max size and a per-session total cap (reuse the plan-014
  25 MB ceiling as the session total), content-type asserted on `final`/reassembly.
- **Reassembly:** at `commit`, if chunks are present, concatenate them in `seq` order into the
  session's canonical `audio_files` blob, then the existing `Orchestrator` path runs
  **unchanged** (it downloads one blob → ASR once → structuring). A session may use *either*
  the single-shot `audio` upload *or* chunks, not both; commit picks whichever is present.
- **Lifecycle:** `created → uploading` (as chunks arrive) `→ processing` (commit) `→
  completed/partial/failed`. No new statuses; `uploading` just becomes chunk-aware.
- **Validation at commit:** reject commit with a clear error if no audio (neither a
  single-shot blob nor any chunk) is present. `final: true` is an optional hint that lets
  `audio/status` report completeness; `commit` itself is the authoritative "done uploading"
  signal and reassembles whatever chunks exist.

### 5.3 Inline form schema

The `form` output accepts an inline `fields` array as an alternative to `page_id`:

```jsonc
// POST /api/v2/scribe_sessions  → outputs[]
{ "type": "form", "fields": [
  { "key": "heart_rate", "label": "Heart Rate", "type": "number", "description": "beats per minute" },
  { "key": "on_insulin", "label": "On insulin", "type": "boolean" },
  { "key": "severity",   "label": "Severity",   "type": "single_select", "enum": ["mild","moderate","severe"] },
  { "key": "symptoms",   "label": "Symptoms",   "type": "multi_select",  "enum": ["fever","cough","fatigue"] }
]}
```

- **Field contract:** `key` (result key, required, unique), `label` (human name for the
  prompt), `type ∈ {string, number, boolean, single_select, multi_select}` (Medispeak's
  existing 5), optional `description`, `enum` (required for the two select types), optional
  `minimum`/`maximum` (injected into the description + validated post-call, matching current
  behavior). No new field types.
- **Reuse the seam:** add an `InlineField` value object that `Scribe::SchemaBuilder` consumes
  the same way it consumes `FormField`/the synthetic `NoteField` today (duck-typed on the 7
  schema methods). No change to `SchemaBuilder`'s core-schema logic — it stays the single
  source of truth.
- **Validation:** `validate_outputs` accepts `fields` **xor** `page_id` for a `form` output
  (both/neither → `validation_error`). Inline fields are stored on the `scribe_output`
  (a `fields`/`schema` JSON column) so the job can rebuild the schema without a Page.
- **Result shape:** `result` is a JSON object keyed by each field `key` (unchanged
  extraction/validation/repair pipeline). This is what lets a caller extract against a form
  it defines at runtime — no pre-created Pages.

### 5.4 Browser CORS + hardening

- Scope `config/initializers/cors.rb` to `/api/*` (closes the SEC-08 wildcard on the HTML/admin
  surfaces), allow the headers/methods the SDK needs (`Authorization`, `Content-Type`, GET/POST),
  keep `credentials: false` (bearer tokens, no cookies).
- Session-token auth (5.1) and per-chunk idempotency (5.2) are the main new trust-boundary
  surfaces — both get request specs (§9).

## 6. SDK — `@medispeak/scribe-ts-sdk` (new repo)

A framework-agnostic core + a thin React hook. `tokenProvider`-based auth; the app supplies a
function that returns a scoped session token (from its own backend). Illustrative surface:

```ts
const client = createScribeClient({
  baseUrl: "https://api.medispeak.…/api/v2",
  getToken: async (sessionId) => fetchScopedTokenFromMyBackend(sessionId), // 5.1
});

const session = await client.startSession({
  outputs: [{ type: "form", fields }, { type: "transcript" }],   // 5.3 inline fields
  language: ["auto"],
  mode: "consultation",
});

await session.record();                 // MediaRecorder capture + chunk streaming (5.2)
session.pause(); session.resume();
await session.stop();                    // finalize upload → commit
const result = await session.result();   // { transcript?, structuredData?: Record<key, value> }
session.cancel();
```

**SDK owns:** mic capture (`MediaRecorder`), chunking (~5 s segments) with resumable upload
(consult `audio/status`, retry missing seqs), commit, polling `GET :id` to a terminal status,
error/retry, and mapping Medispeak `outputs[]` → `{ transcript, structuredData }`. It does **not**
own token issuance (the app's backend does) or any account secret.

**Contract stability:** the SDK talks only to the documented v2 routes + the new
5.1/5.2/5.3 surface. Its public types are Medispeak-native (sessions, outputs, fields) — not
borrowed from any incumbent SDK.

## 7. Data flow (end to end)

1. App backend: `POST /scribe_sessions` with the desired `outputs` (inline `fields` for the
   form) using its `msk_live_` token → `{ id }`; then `POST /:id/tokens` → scoped token.
2. App hands `{ id, token }` to the browser.
3. SDK records; streams chunks to `POST /:id/audio/chunks` during capture; resumes via
   `GET /:id/audio/status` on any drop.
4. On stop: `POST /:id/commit` → backend reassembles chunks → `ProcessScribeSessionJob` →
   `Orchestrator` (ASR once → structuring against the inline schema).
5. SDK polls `GET /:id` (or the app receives the existing HMAC webhook) → maps
   `outputs[].result` to `{ transcript, structuredData }`.

## 8. Security & PHI

- **No account secret in the browser** — only a short-lived, single-session, upload+read token.
- **Least privilege** — session tokens can't create, commit-across-sessions, list, or read
  usage; they're bound to one `sid` and expire in minutes.
- **CORS scoped** to `/api/*`, credentials off.
- **Transport** — HTTPS only; existing HMAC webhooks unchanged; existing `callback_url` SSRF
  validation unchanged.
- **PHI minimization** — audio chunks are transient parts reassembled then treated like any
  session blob (subject to the same retention/purge follow-up already tracked for sessions).

## 9. Testing strategy

- **Session tokens:** mint requires the owning account token; a session token works for its
  own `audio/chunks|status|commit|show` and is rejected (`401`) for another session, for
  account routes, and after expiry.
- **Chunked upload:** out-of-order seqs reassemble correctly; re-POSTing a seq is idempotent;
  `audio/status` reports gaps; resume-then-commit yields the same transcript as a single-shot
  upload (golden equivalence); commit with no audio errors cleanly.
- **Inline schema:** a `form` output with inline `fields` (all 5 types incl. `multi_select`
  `items.enum` and a min/max field) produces a `key`-keyed result equal to the stored-`page_id`
  path for an equivalent form; `fields` xor `page_id` enforced.
- **SDK:** unit tests with mocked `fetch` + `MediaRecorder` (chunking, resume, poll, result
  mapping); one end-to-end contract test against a running backend.

## 10. Sequencing / decomposition

**Phase 1 — backend (this repo), the foundation and contract.** Independent plans:
1. Inline form schema (`InlineField` + `SchemaBuilder` seam + `validate_outputs`).
2. Scoped session tokens (mint endpoint + `BaseController` dual-auth).
3. Native chunked + resumable upload (chunk/status endpoints + commit reassembly).
4. Browser CORS scoping.

**Phase 2 — `@medispeak/scribe-ts-sdk` (new repo).** Built against Phase 1; its own spec/plan.

**Phase 3 — reference Care plugin adoption (deferred).** Separate spec once the SDK exists;
swaps the incumbent SDK, emits inline `fields` from its questionnaire fields, fetches scoped
tokens from Care backend, and simplifies its result mapping.

## 11. Risks & open items

- **Chunk reassembly cost/limits.** Concatenating many small blobs at commit must stay within
  memory/time bounds; define a sane per-session cap and chunk-size floor. Verify Disk and
  S3/MinIO reassembly both work.
- **Token TTL vs. long consultations.** A recording longer than the token TTL needs the SDK to
  re-mint mid-session (the `getToken` provider supports this) — confirm the refresh path.
- **Session-token scope creep.** Keep the scope strictly `{audio, read}`; never allow `create`
  or cross-session `commit`. This is the core trust boundary.
- **Structured medical coding.** The incumbent path emitted richer coded structures (e.g.
  SNOMED) for some fields; the inline-schema path returns plain field-keyed values. Sufficient
  for Care questionnaire fill; richer coded output is a later enhancement, not in this spec.
- **Backpressure / abandoned uploads.** Chunks for a session that never commits should be swept
  with the session (ties into the reservation/PHI-purge sweeper work already tracked).
