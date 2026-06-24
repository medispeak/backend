# Model-Agnostic Medispeak — Design Spec

**Date:** 2026-06-24
**Status:** Approved (decisions delegated to implementer)
**Branch:** `feature/model-agnostic-ai`

## 1. Goal

Turn Medispeak from a system hardwired to OpenAI into a **model-agnostic clinical voice platform**:

- Run **any model** for ASR (speech→text) and **any model** for Structuring (text→form/note), in **any combination**, including the operator's **own self-hosted models**.
- Configuration is **runtime, in the database**, resolvable per **template/page** (falling back to account default, then system default).
- Expose a clean, async, **metered public API** to client accounts.
- **Log token/usage** for cost & observability, quotas & rate-limits, client billing, and per-model analytics.

ASR and Structuring are two **independently configurable functions**. A single multimodal model may serve **both** (audio→structured in one call).

## 2. Current system (ground truth)

Rails 8 API, PostgreSQL, `ruby-openai` 6.5.0, `solid_queue`/`solid_cache`/`solid_cable` configured, `delayed_job` also present, Devise auth, Pundit, ActiveStorage (S3/MinIO), Administrate admin.

The entire AI layer lives in `app/helpers/openai_helper.rb`:
- **ASR:** `client.audio.translate(model: "whisper-1", file:)` — hardcoded, and `translate` **always outputs English** (translations endpoint is whisper-1-only). Records **zero** usage.
- **Structuring:** `client.chat(model: "gpt-3.5-turbo-1106", tools: [fill_form])` — hardcoded legacy model, **non-strict** function calling, `required: []`. Sums tokens onto the `transcriptions` row.
- Credentials are ENV-only; the client is a single memoized global.
- `FormField#to_json_schema_for_ai` already emits a provider-neutral core schema (type + `enum`; `minimum`/`maximum` as hints).

Domain: `User → Template → Page(prompt) → FormField`; `Transcription` belongs to user+page; `Domain` maps `fqdn → Template`.

The flow is **synchronous two-call**: `POST /api/v1/pages/:id/transcriptions` (blocks on Whisper) then `POST /api/v1/transcriptions/:id/generate_completion` (blocks on GPT). API auth is a plaintext Bearer `ApiToken`. No accounts, quotas, or metering.

## 3. Locked decisions

| Area | Decision |
|------|----------|
| Tenancy | New **Account/Organization** layer above User. API keys, model config, usage, quotas, billing scope to the account. |
| Provider scope | Full **mix-and-match**: any provider for ASR, any for structuring, any combination. Thin in-process adapter layer (no external gateway in v1). |
| Credentials | **Operator-managed** (you configure providers/models/keys centrally). No client BYO-key API in v1, but the schema doesn't preclude it. |
| Config level | **Per template/page**, resolving Page → Account → System default. |
| Usage logging | All four goals: cost/observability, quotas & rate-limits, client billing, per-model analytics. |
| Processing | **Async**, session/job based, on `solid_queue`. |
| Streaming | **Batch now**, data model + adapter interface kept streaming-friendly. |
| API compatibility | **Greenfield** `/api/v2`. v1 is shimmed onto the new engine, then retired. |
| Output | **Form-fill (schema) + templated clinical notes**, multiple outputs per session. |
| Language | **English output** by default, but as an explicit configurable `mode`, not a hardcoded `translate` call. |
| Diarization | **Not required v1**; data model carries speaker labels for later. |
| Compliance | **No hard constraint v1**; self-hosting must remain possible. |

## 4. Architecture

The API layer never references a model. It calls an **orchestrator** that composes **stages** (ASR, Structuring), each backed by a **provider adapter** resolved from DB config. A `UsageRecorder` wraps every adapter call so metering can't be forgotten.

```
Client (SDK/EMR) ──Bearer msk_live_…──► Api::V2::ScribeSessionsController
                                          auth → rate-limit/quota → idempotency → enqueue
                                                          │
                                                          ▼
                              ProcessScribeSessionJob (solid_queue)
                                          │
                                  Scribe::Orchestrator  (reads requested outputs)
                                     │                       │
                                  AsrStage             StructuringStage   (or CombinedStage)
                                     │                       │
                                  Llm::ConfigResolver  (Page → Account → System)
                                     │                       │
                                  Llm::Adapter  (OpenAICompatible | Anthropic | …)
                                     │  .transcribe / .structure → normalized Result+usage
                                  UsageRecorder wraps every call
                                          │
        OpenAI · Groq · self-hosted Whisper/vLLM · Anthropic · Gemini (openai-compat) …
```

### 4.1 Module layout

```
app/services/llm/
  config.rb            # value object: provider, model, base_url, api_key, timeout, options, fallback
  config_resolver.rb   # most-specific-wins resolution → Llm::Config
  result.rb            # normalized { text, structured, model, provider, usage, latency_ms, finish_reason, raw }
  usage.rb             # { input_tokens, output_tokens, total_tokens, audio_seconds }
  registry.rb          # maps provider kind → adapter class
  errors.rb            # Llm::Error hierarchy (Timeout, RateLimited, BadResponse, SchemaTooComplex, Refused)
  adapter.rb           # abstract: #transcribe(audio, opts) / #structure(input, schema, opts)
  adapters/
    openai_compatible.rb   # OpenAI, Groq, vLLM, Ollama, LM Studio, self-host (uri_base)
    anthropic.rb           # Claude (different tool/output-config shape)
    # gemini.rb            # later

app/services/scribe/
  orchestrator.rb      # composes stages from requested outputs + resolved configs
  asr_stage.rb         # audio → Transcript (normalized)
  structuring_stage.rb # transcript + schema/prompt → structured result / note
  combined_stage.rb    # audio → structured (single multimodal model)
  schema_builder.rb    # Page/FormFields → core JSON Schema (provider-neutral)
  schema_validator.rb  # json_schemer validate + one bounded repair re-ask

app/services/metering/
  usage_recorder.rb    # wraps adapter calls: reserve(pending) → finalize/fail, cost calc
  price_book.rb        # resolve effective ModelPrice / AudioModelPrice at a timestamp
  quota_guard.rb       # credit-ledger check + atomic deduction
```

### 4.2 Provider abstraction (Section 3 detail)

**`Llm::Config`** — immutable value object built by the resolver:
`provider_kind`, `api_model_id`, `base_url`, `api_key`, `organization_id`, `request_timeout`, `capabilities` (hash), `options` (language/mode/temperature/etc.), `fallback` (another `Llm::Config` or nil).

**`Llm::ConfigResolver.call(function:, page:, account:)`** — finds the most-specific `ModelAssignment` (`scope=Page` → `scope=Account` → `scope=System`) for `function ∈ {asr, structuring, combined}`, loads its `AiModel` + `AiProvider`, decrypts the key, and returns a `Llm::Config` (with the assignment's `fallback_ai_model_id` resolved into `config.fallback`). Defaults read from ENV when no DB rows exist (backward-compatible bootstrap).

**`Llm::Adapter`** — two methods, both returning a normalized `Llm::Result` carrying `usage`:
- `#transcribe(audio_io, language:, mode:, diarize:, timestamps:)` → `Result(text:, raw segments/words/speakers, usage.audio_seconds)`
- `#structure(messages:, schema:, mode:)` → `Result(structured:, usage.input/output_tokens, finish_reason:)`

`OpenaiCompatibleAdapter` builds a per-call `OpenAI::Client.new(access_token:, uri_base:, request_timeout:)` from the `Llm::Config` — **no global client**. The *same* code targets OpenAI, Groq, vLLM, Ollama, LM Studio, or any self-host by changing `base_url` + `api_model_id`. **"Run your own model"** = an `AiProvider(kind: openai_compatible, base_url: "http://host:8000/v1")` + an `AiModel(api_model_id: "<whatever>")`; the adapter never validates model names against a catalog.

`AnthropicAdapter` uses the official `anthropic` gem (or Faraday) and translates the core schema to Anthropic's tool/`output_config` shape; Claude has **no audio endpoint**, so its `AiModel.capabilities.can_transcribe = false`.

**Fallback** is an in-process loop in `UsageRecorder`/stage: try primary `Llm::Config`, on `Llm::Timeout`/`RateLimited`/`BadResponse` try `config.fallback` once, recording usage for whichever actually ran. No declarative gateway in v1; a LiteLLM gateway can be slotted behind `AiProvider(kind: openai_compatible)` later with zero call-site changes.

**Security:** `AiProvider.api_key` uses Rails 8 `encrypts`. Never log decrypted keys. Replace the current `handle_openai_error` (which interpolates `error.message` into client-facing text) with scrubbed messages + a `request_id`; full detail goes to server logs only.

### 4.3 ASR function (Section 3 detail)

- **Use `audio.transcribe`, not `audio.translate`.** `mode` is an explicit option: `:transcribe` (source language, portable to all providers) or `:translate` (English, OpenAI-whisper-1-only — gated by capability). Default behavior for "English output": transcribe in source language, and produce English at the **structuring** layer (form fields and notes are English) — this is provider-portable and preserves a faithful source transcript for audit. An explicit `transcript` output in English is produced by a lightweight LLM translation step only when requested.
- **Audio path is the least portable surface** — gate ASR providers by `capabilities.can_transcribe`. Self-hosted vLLM/faster-whisper expose `/v1/audio/transcriptions` (works) but not `/v1/audio/translations`.
- **Adapter normalizes:** input (ActiveStorage blob/file/S3), per-provider size limits (OpenAI 25MB, Groq 100MB) with ffmpeg silence-boundary chunking for long audio; `language_hint`; `mode`; `diarize`; `timestamps`. Returns `{text, language, segments[], words[], speakers[], duration_seconds, provider, model}`.
- **First providers:** OpenAI (`whisper-1`, `gpt-4o-transcribe`), Groq (`whisper-large-v3-turbo`, cheap batch), self-hosted Whisper via `base_url`. OpenAI feature support varies by model (only `whisper-1` does `timestamp_granularities`; `gpt-4o-transcribe` has none) — the adapter maps requested features → a valid model or drops unsupported options with a logged warning.
- **`duration_seconds` must be measured reliably** (blob metadata / ffprobe) — ASR is billed per-minute, so a missing duration silently undercharges.

### 4.4 Structuring function (Section 3 detail)

- **Schema:** keep `FormField#to_json_schema_for_ai`; `Scribe::SchemaBuilder` assembles the page's fields into one core schema. The 5 field types map to the universal enforced subset:
  `string→{type:string}`, `number→{type:number}`, `boolean→{type:boolean}`, `single_select→{type:string,enum}`, `multi_select→{type:array,items:{type:string,enum}}`.
  `enum` is enforced everywhere; **`minimum`/`maximum` are NOT** enforced by any strict engine → inject into the field `description` AND validate in Ruby post-call.
- **Prefer `response_format: json_schema` (strict) over the `fill_form` tool.** We always want exactly one object back; tool-calling adds a "did it call the tool?" failure mode. Use tool-calling only for models flagged `supports_function_calling && !supports_json_schema`.
- **Per-provider schema transforms** isolated in each adapter:
  - OpenAI strict: every property in `required`; "optional" = type union `["string","null"]`; `additionalProperties:false`; root object.
  - Anthropic strict: real `required` subset allowed; caps (~24 optional / 16 union params / 20 tools) → large forms may need **split extraction**; on "schema too complex" 400 the stage splits the schema and merges results.
  - Gemini: `responseSchema` + `responseMimeType`; set `required`/optional explicitly (default inverts across SDKs).
- **Normalize optional semantics to nullable-everywhere** so the same form yields `{field:null}` consistently (not `{}` on some providers).
- **Validate + repair:** branch on `finish_reason`/`stop_reason` **first** (truncation/refusal return 2xx with bad output). Validate against the *full* schema (incl. min/max) with `json_schemer`; on failure do **one** bounded re-ask including the errors (Instructor pattern). The biggest single reliability win is dropping `gpt-3.5-turbo-1106` for a current model with `strict` on.
- **Notes output:** a `note` output type runs the structuring model in free-text mode with a template prompt (`template_ref`), producing markdown/text rather than a schema fill.

### 4.5 Single-model-does-both (Section 3 detail)

`CombinedStage` is selected when a Page has a `ModelAssignment(function: combined)` whose `AiModel.capabilities` has `accepts_audio && can_structure`. It sends audio + schema in one call (e.g. Gemini 2.5 `responseSchema` from audio; gpt-4o-audio function-calling — note gpt-4o-audio does **not** support strict json_schema from audio, so validate/repair is mandatory). The orchestrator **always persists a transcript** — for combined models, it requests a `transcript` field inside the schema so the audit artifact is never lost.

**Default = cascaded** (cheaper per minute, swappable ASR, inspectable transcript, re-runnable structuring without re-billing audio). Combined is opt-in per page. Orchestrator inspects capability flags, never hardcodes model names; if `can_transcribe && !native_diarization` and diarization is later requested, it can insert a separate diarization stage.

## 5. Data model

**Kept:** `Template`, `Page`, `FormField`. **Superseded:** old `Transcription` (role splits into `ScribeSession`/`Transcript`/`ScribeOutput`; rows backfilled into `usage_events`, then table retired).

### 5.1 Tenancy & auth
- **`accounts`**: `name`, `status`, `settings jsonb`, `webhook_secret`, `default_callback_url`, timestamps. `has_many :users, :api_tokens, :model_assignments, :scribe_sessions, :usage_events`; `has_one :account_credit`.
- **`users`** (changed): add `account_id` (nullable during migration; backfill one account per existing user).
- **`api_tokens`** (changed): add `account_id`; replace plaintext `token` with `token_digest` (SHA-256) + `token_prefix` (`msk_live_…` for secret-scanning) + `scopes string[]`. Keep `user_id` as creator. Lookup by digest.

### 5.2 Model config & catalog (operator-managed)
- **`ai_providers`**: `name`, `kind` (`openai_compatible`/`anthropic`/`gemini`), `base_url`, `encrypted_api_key`, `organization_id`, `request_timeout`, `active`.
- **`ai_models`** (belongs_to provider): `api_model_id`, `display_name`, `capabilities jsonb` (`accepts_audio`, `can_transcribe`, `can_structure`, `supports_json_schema`, `supports_function_calling`, `native_diarization`), `active`.
- **`model_assignments`**: `scope_type` (`System`/`Account`/`Page`), `scope_id` (null for System), `function` (`asr`/`structuring`/`combined`), `ai_model_id`, `fallback_ai_model_id`, `options jsonb`. Unique on `(scope_type, scope_id, function)`.

### 5.3 Scribe domain
- **`scribe_sessions`**: `account_id`, `api_token_id`, `user_id?`, `status` (`created`/`uploading`/`processing`/`completed`/`partial`/`failed`/`expired`), `language`, `mode` (`dictation`/`consultation`), `idempotency_key` (unique per token), `callback_url`, `expires_at`, `error jsonb`. `has_many_attached :audio_files`; `has_one :transcript`; `has_many :scribe_outputs`.
- **`transcripts`**: `scribe_session_id`, `text`, `language`, `duration_seconds`, `provider`, `model`, `segments jsonb`, `words jsonb`, `speakers jsonb`. Always persisted.
- **`scribe_outputs`**: `scribe_session_id`, `output_type` (`transcript`/`form`/`note`), `page_id?`, `template_ref?`, `status` (`pending`/`success`/`partial`/`failure`), `result jsonb`, `errors jsonb`.

### 5.4 Metering & billing
- **`usage_events`** (append-only source of truth): `account_id`, `api_token_id`, `scribe_session_id?`, `scribe_output_id?`, `function` (`asr`/`structuring`), `provider`, `model`, `model_version`, `input_tokens`, `output_tokens`, `total_tokens`, `audio_seconds`, `unit_price_input/output/audio_min` (snapshotted), `cost decimal(12,6)`, `currency`, `latency_ms`, `status` (`pending`/`finalized`/`failed`), `request_id`, `idempotency_key` (unique). Indexes: `(account_id, created_at)`, `(account_id, model)`, unique `idempotency_key`.
- **`account_usage_daily` / `account_usage_monthly`**: derived rollups, rebuildable from events.
- **`model_prices`** (versioned): `provider`, `model`, `input_per_million`, `output_per_million`, `effective_at`, `deprecated_at`.
- **`audio_model_prices`** (versioned): `provider`, `model`, `price_per_minute`, `effective_at`, `deprecated_at`. (ASR billed per minute.)
- **`account_credits`**: `credits_allocated`, `credits_used`, `credit_limit`, `refill_period`, `balance`.
- **`credit_transactions`**: `type` (`deduction`/`allocation`/`refund`/`adjustment`), `amount`, `balance_before`, `balance_after`, `usage_event_id`.

Every `usage_event` snapshots **both raw counts and resolved cost** (counts → recompute on price change; cost → freeze what was charged).

## 6. Metering & billing flow

1. **On request** (controller): `QuotaGuard` checks the credit ledger and rate limit. A `usage_event(status: pending)` reservation is written keyed by `idempotency_key` **before** enqueuing. Pending rows count as reserved spend so in-flight bursts can't exceed the cap.
2. **In the job**, each adapter call is wrapped by `UsageRecorder`: it captures provider-reported usage (`response["usage"]` for OpenAI), resolves price via `PriceBook` at event time, computes `cost`, and **finalizes the same row** (`pending → finalized`), or marks `failed`.
3. **Credit deduction** on finalize is a single atomic conditional `UPDATE` (guard double-spend under concurrency); **refund** on failure.
4. **Rate limiting:** `rack-attack` (new gem) keyed on the bearer token, backed by `solid_cache`, emitting `429` + `RateLimit-Limit/Remaining/Reset` + `Retry-After`. Per-account TPM/RPM read from account settings.
5. **Reconciliation:** monthly job diffs `SUM(usage_events.cost)` per provider vs provider invoice; alert if delta > ~3%.

## 7. Public API & SDK (v2)

Bearer `ApiToken` auth (`Authorization: Bearer msk_live_…`), JSON, versioned under `/api/v2`. Standard error envelope `{error: {code, message, request_id, details}}` with stable codes (`validation_error`, `unauthorized`, `rate_limited`, `session_not_found`, `session_expired`, `audio_upload_failed`, `processing_failed`).

| Method & path | Purpose |
|---|---|
| `POST /api/v2/scribe_sessions` | Create. Body: `outputs:[{type:transcript}|{type:form,page_id}|{type:note,template_ref}]`, `language_hint`, `mode`, `callback_url`. Header `Idempotency-Key`. Returns `id`, `status:created`, `expires_at`, upload target. **Decoupled from a single page** — one session can yield transcript + several forms + a note. |
| `POST /api/v2/scribe_sessions/:id/audio` | Upload audio. Single file now (raw binary `audio/*` or multipart); chunked `:seq` ordering reserved for later; presigned-S3 direct variant for large/browser uploads. |
| `POST /api/v2/scribe_sessions/:id/commit` | `202 Accepted`, `status:processing`, enqueues the job. Idempotent. |
| `GET /api/v2/scribe_sessions/:id` | Poll: `200` done · `202` processing · `206` partial. Each output carries its own `status` + `errors` so one failed form doesn't fail the session. |
| `GET /api/v2/scribe_sessions` | List. |
| `GET /api/v2/config` | Discovery: supported languages, templates, limits. |
| `GET /api/v2/usage` | Account usage summary (from rollups). |

**Idempotency:** `Idempotency-Key` (UUIDv4) on create + commit; first response persisted per `(api_token, key)` ~24h, replayed on retry, `409` on conflicting payload — prevents double-billing on retries.

**Webhooks (primary) + polling (fallback):** on completion POST a **PHI-light** signed payload (`session_id` + summary; full results via GET) to `callback_url`. Header `X-Medispeak-Signature: t=<unix>,v1=<hex>` where `v1=HMAC-SHA256(secret, "<t>.<raw_body>")` — sign the **raw** body; constant-time verify; ~5-min replay window; at-least-once with exponential backoff.

**PHI:** `format_transcription` currently returns `url_for(audio_file)` (long-lived/unsigned). v2 uses short-lived signed URLs only.

**SDK shape (TS + Ruby):** mirror REST 1:1, plus a one-call `client.scribe.transcribe(file, outputs:[…])` that hides create→upload→commit→poll, and granular methods (`create_session`/`upload_audio`/`commit`/`get_result`/`wait_for_result`) for advanced use.

**v1 compatibility:** v1 controllers are reimplemented as thin shims that create a single-page synchronous session against the new engine, so the existing plugin keeps working during transition; v1 is then deprecated.

## 8. Migration / sequencing

Each step is independently shippable and backward-compatible.

1. **Bug fix + safety:** `audio.translate → audio.transcribe` with explicit `mode` + `language`; scrub `error.message` from client-facing errors. Fixes the silent English-anglicization of vernacular audio.
2. **Adapter + resolver seam:** extract `OpenaiHelper` → `Llm::OpenaiCompatibleAdapter` returning a normalized `Result`; add `Llm::Config` + `ConfigResolver` (ENV defaults). No behavior change. Chat and audio are separate adapter methods.
3. **Structuring reliability:** drop `gpt-3.5-turbo-1106`; `response_format json_schema` + `strict`; `json_schemer` validate+repair; `finish_reason` branching; optional→nullable.
4. **Background jobs:** `ProcessScribeSessionJob` on `solid_queue`; move ASR + structuring off the request thread.
5. **Tenancy + metering schema:** `Account` + `api_tokens.account_id` + hashed tokens; `usage_events` + price book + `UsageRecorder`; backfill/dual-write from `transcriptions`. Capture `audio_seconds`.
6. **DB-backed config:** `ai_providers`/`ai_models`/`model_assignments` with `encrypts`; resolver reads DB (most-specific) with ENV fallback. "Run your own model" now works via a config row + `base_url`.
7. **Capability flags + 2nd provider:** add flags; add `AnthropicAdapter` (proves the abstraction on a genuinely different provider; unlocks Claude structuring + the mix-and-match goal). Combined-stage support.
8. **Quotas + rate limiting:** `rack-attack` edge throttle + credit ledger with atomic deduction.
9. **New async v2 API + SDK:** `scribe_sessions` resource, idempotency, webhooks; v1 shimmed; deprecate v1.
10. **Optional gateway:** LiteLLM only if per-tenant budget enforcement at scale ever demands it.

**Build first:** 1–3 (correctness wins, near-zero infra, prerequisites for everything else).

## 9. Testing strategy

Minitest (existing). Add `webmock` to stub provider HTTP.
- **Adapter contract tests:** each adapter, given a stubbed provider response, returns a correct normalized `Result` + `usage`. One shared "adapter contract" test module run against every adapter.
- **Resolver tests:** Page → Account → System precedence; ENV fallback; fallback-config resolution.
- **SchemaBuilder/Validator tests:** all 5 field types → correct core schema; optional→nullable; min/max in description + post-validation; one-shot repair on invalid output.
- **Orchestrator tests:** with **fake stages**, compose cascaded vs combined; per-output status isolation (one failure ⇒ `partial`, others succeed).
- **Metering tests:** pending→finalized lifecycle; cost math (token & per-minute); atomic credit deduction under simulated concurrency; refund on failure; idempotency-key dedupe.
- **API request tests:** session lifecycle status codes (`201/202/200/206`); idempotency replay; rate-limit `429` + headers; HMAC webhook signature (raw-body, constant-time, replay window).
- **v1 shim tests:** existing endpoints still return the prior contract.

## 10. Risks & open items

- **No public benchmark covers Indian medical audio.** Before defaulting an ASR model, run an empirical bake-off (Sarvam vs Deepgram Nova-3 Medical vs gpt-4o-transcribe-with-prompt vs self-hosted Whisper) on real consultation audio. Tracked as an ops task, not a code blocker.
- **Anthropic strict schema caps** (~24 optional / 16 union params) — large clinical forms may need split extraction; the structuring stage handles the 400 by splitting.
- **Audio duration measurement** must be reliable or ASR under-bills.
- **Credit deduction race-safety** depends on a single atomic conditional UPDATE — not the ledger rows alone.
- Greenfield v1 replacement: confirm how many integrators depend on the synchronous flow before retiring v1 (shim covers the window).
