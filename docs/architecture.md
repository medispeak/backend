# Architecture

Medispeak is a model-agnostic clinical AI engine with two modalities: audio
scribe (ASR) and lab-report OCR (vision). The API layer never names a model —
it calls an **orchestrator** that composes **stages** (ASR or OCR, then
structuring), each backed by a **provider adapter** resolved from runtime
config that cascades down a **tenancy tree** (org → program → facility). A
metering layer records usage per physical attempt (tokens, audio minutes,
pages), settles it against a credit ledger, and enforces per-user/per-subtree
usage limits at admission time.

This document describes the seams and the async request lifecycle. For the REST
surface see [api/v2.md](./api/v2.md); for wiring up models see
[configuration.md](./configuration.md).

---

## The seam: `Llm::*`

The provider abstraction lives in `app/services/llm/`.

| Component                 | Responsibility |
|---------------------------|----------------|
| `Llm::Config`             | Immutable value object for one resolved call: `provider_kind`, `api_model_id`, `base_url`, `organization_id`, `request_timeout`, `capabilities`, `options`, `fallback`, and a **lazy `#api_key`** (decryption deferred until a call is made). |
| `Llm::ConfigResolver`     | Resolves a `Config` for a function (`asr`/`structuring`/`ocr`) using the most-specific `ModelAssignment` (Page → Template → Account → ancestor accounts up the tenancy tree → System). Resolves the optional fallback model into `config.fallback`. |
| `Llm::DefaultConfigProvider` | ENV-based fallback `Config` (OpenAI defaults: `whisper-1` for ASR, `gpt-4o-mini` for structuring and OCR) when no `ModelAssignment` exists. |
| `Llm::Caller`             | The **single owner of fallback**. Tries the primary config; on a transient error (`Timeout`/`RateLimited`/`BadResponse`) tries `config.fallback` once. Refusals are not retried. |
| `Llm::Registry`           | Maps a provider kind to its adapter class. |
| `Llm::Adapter` (+ `adapters/`) | Abstract base + concrete adapters (`OpenaiCompatible`, `Anthropic`, `Sarvam`). Each exposes `#transcribe`, `#structure`, and `#ocr` (vision-capable adapters only — others raise), and maps `Faraday::Error` to the `Llm::Error` hierarchy. |
| `Llm::Result` / `Llm::Usage` | Normalized result + usage structs so callers never inspect provider-specific JSON. |

**Adapters** translate one normalized contract to each provider:

- `OpenaiCompatible` — OpenAI and any OpenAI-compatible endpoint (Groq, vLLM,
  Ollama, LM Studio, self-hosted Whisper). Builds an `OpenAI::Client` per call
  from the `Config` (`uri_base`, `access_token`, `request_timeout`). For
  structuring with `supports_json_schema`, it sends a **strict** JSON schema
  (`additionalProperties: false`, every prop required, optional expressed as a
  nullable type union).
- `Anthropic` — talks to the Messages API over Faraday. Structuring uses a single
  forced tool call (`extraction`) whose `input_schema` is the core schema.
  `#transcribe` raises — Anthropic has no audio endpoint.

**Error mapping** (`Llm::Error` subtypes): a provider 429 becomes
`RateLimited`, a transport timeout becomes `Timeout`, and a non-2xx / parse
failure becomes `BadResponse`. Upstream messages/headers are not leaked to
callers. When a provider omits a usage block, the adapter returns a `Usage` with
`estimated: true` rather than silently billing zero.

---

## The pipeline: `Scribe::*`

`app/services/scribe/` composes the stages for one session.

| Component                  | Responsibility |
|----------------------------|----------------|
| `Scribe::Orchestrator`     | Runs the cascaded pipeline for one `ScribeSession`: source extraction **once** (segment assembly, whole-file ASR, or document OCR by modality — shared by all outputs), then each output independently, then rolls up the session status. |
| `Scribe::AsrStage`         | audio → normalized transcript via `Llm::Caller.transcribe`. |
| `Scribe::OcrStage`         | lab-report documents (PDF/images) → full extracted text via `Llm::Caller.ocr` ("transcribe, don't summarize"; tables as markdown). |
| `Scribe::StructuringStage` | transcript + field schema/prompt → validated structured object via `Llm::Caller.structure`, with `finish_reason` guarding and one bounded validate-and-repair re-ask. |
| `Scribe::SchemaBuilder`    | Page/FormFields + context → core JSON Schema (single source of truth). |
| `Scribe::SchemaValidator`  | Validates the structured output and drives the repair re-ask. |
| `Scribe::WebhookSigner`    | Computes the `X-Medispeak-Signature` value. |

**Orchestrator flow:**

1. **Extract once** — ONE transcript-source rule per modality, no cross-source
   fallback:
   - `document` → vision OCR over the uploaded documents (`OcrStage`).
   - `audio` **with** transcription segments → assemble from the ordered
     segment texts ONLY. Each segment was transcribed + metered on arrival
     (`TranscribeSegmentJob`, atomic claim); `ProcessScribeSessionJob` settles
     stragglers via bounded **job continuation** (re-enqueue, never an in-job
     poll). A segment set that did not fully settle is an **explicit failure
     naming the unsettled seqs** — re-commit retries exactly those segments.
   - `audio` **without** segments → whole-file ASR (`AsrStage`).
   The extracted text persists as the session's `Transcript`. If extraction
   fails, the session and **every** output are marked failed and it returns
   early (nothing to structure).
2. **Per output, isolated** — for each `scribe_output`:
   - `transcript` → echo the transcript text/language (no LLM call).
   - `form` → run `StructuringStage` against the page's form fields. Valid →
     `success`; invalid-but-parsed → `partial` with `result_errors`.
   - `note` → run `StructuringStage` against a synthetic single `note` field in
     free-text mode (prompt from `template_ref` or the page prompt).
   - A failure in one output sets that output to `failure` and records the
     message in `result_errors` without aborting siblings.
3. **Roll up** — `completed` (all success), `failed` (all failure), or `partial`
   (any mix).

Metering for each physical attempt runs **outside** the per-output rescue so a
metering error can never demote a finalized success or fail the session.

---

## The meter: `Metering::*`

`app/services/metering/`.

| Component                  | Responsibility |
|----------------------------|----------------|
| `Metering::UsageRecorder`  | Pure per-attempt meter. From a normalized `Llm::Result` it prices the call via `PriceBook`, snapshots unit prices, attributes the acting `user_id`, and persists a `UsageEvent`. **One metering rule:** every successful physical attempt records exactly one dedupe-keyed `UsageEvent`; assembly and echo are never metered. |
| `Metering::PriceBook`      | Computes cost from versioned `ModelPrice` (per-million tokens), `AudioModelPrice` (per-minute), and `DocumentModelPrice` (per-page, optional) tables, effective at a timestamp. Never raises on a missing price — it returns zeros so metering degrades gracefully. |
| `Metering::QuotaGuard`     | Ledger-backed quota enforcement against `AccountCredit` + `CreditTransaction`: `hold!` (at commit), `deduct!` (on finalize), `refund!`. Accounts without an `AccountCredit` are treated as unlimited (no-ops). |
| `Metering::LimitGuard`     | Pure-read admission gate for `UsageLimit` caps (subtree/per_user × tokens/cost × daily/monthly). Windowed sums over `usage_events`; every limit on the account's leaf-to-root chain must pass at commit. NOT a second ledger. |

See [metering-and-billing.md](./metering-and-billing.md) for details.

---

## Async request lifecycle

```
Client ──Bearer msk_live_…──► Api::V2::ScribeSessionsController
  │
  │  POST /scribe_sessions      create the session + outputs        ► 201
  │  POST /:id/audio            attach audio blob (status: uploading)► 200
  │  POST /:id/commit ──────────┐
  │                             │  QuotaGuard.hold!(estimate: 0)
  │                             │  session → processing
  │                             │  enqueue ProcessScribeSessionJob   ► 202
  │                             ▼
  │                 ProcessScribeSessionJob  (solid_queue; :inline in test)
  │                             │  session → processing
  │                             ▼
  │                 Scribe::Orchestrator
  │                   │  ensure_transcript!  (ASR once → Transcript)
  │                   │     └─ Llm::ConfigResolver(:asr) → AsrStage → Llm::Caller.transcribe
  │                   │     └─ UsageRecorder.record + QuotaGuard.deduct!   (per attempt)
  │                   │  for each output:
  │                   │     └─ StructuringStage → Llm::Caller.structure → SchemaValidator
  │                   │     └─ UsageRecorder.record + QuotaGuard.deduct!   (per attempt)
  │                   │  finalize session status (completed/partial/failed)
  │                             │
  │                             ▼  (if callback_url present)
  │                 ScribeWebhookJob  ──► POST callback_url
  │                             │         X-Medispeak-Signature: t=…,v1=HMAC(secret,"t.body")
  │                             │         PHI-light body incl. delivery_id
  ▼
GET /scribe_sessions/:id   poll  ► 202 processing · 200 done · 206 partial
```

**Key properties:**

- **ASR is shared.** It runs once per session; all form/note outputs structure
  the same transcript. A re-run can structure an existing transcript without a
  new ASR event.
- **One usage event per physical attempt.** Recording and ledger deduction are
  best-effort and isolated — a metering failure never changes an output's status
  or fails the session.
- **Jobs do not re-raise.** `ProcessScribeSessionJob` marks the session `failed`
  with a sanitized message on an unexpected error rather than retrying forever.
  `ScribeWebhookJob` swallows Faraday transport errors so delivery can be retried
  (at-least-once).
- **Webhooks are PHI-light.** The body carries only ids/statuses/timestamps and a
  `delivery_id`; full results are fetched via the authenticated GET endpoint.
- **Rate limiting** is enforced by `rack-attack` at the middleware layer, keyed on
  the resolved account id (`config/initializers/rack_attack.rb`).

For the metering and webhook details, continue to
[metering-and-billing.md](./metering-and-billing.md) and the webhook section of
[api/v2.md](./api/v2.md).
