# Model-Agnostic Medispeak — Design Spec

**Date:** 2026-06-24
**Status:** Approved (decisions delegated to implementer). Revised after adversarial spec review.
**Branch:** `feature/model-agnostic-ai`

## 1. Goal

Turn Medispeak from a system hardwired to OpenAI into a **model-agnostic clinical voice platform**:

- Run **any model** for ASR (speech→text) and **any model** for Structuring (text→form/note), in **any combination**, including the operator's **own self-hosted models**.
- Configuration is **runtime, in the database**, resolvable per **template/page** (falling back to account default, then system default).
- Expose a clean, async, **metered public API** to client accounts.
- **Log token/usage** for cost & observability, quotas & rate-limits, client billing, and per-model analytics.

ASR and Structuring are two **independently configurable functions**. A single multimodal model may serve **both** (audio→structured in one call) — this is designed for but deferred to post-v1 (§4.5).

## 2. Current system (ground truth)

Rails 8 API, PostgreSQL, `ruby-openai` (Gemfile pins `~> 6.2`; `6.5.0` in lock), `solid_queue`/`solid_cache`/`solid_cable` present, `delayed_job` present-**but-unused** (dead dependency, to be removed), Devise auth, Pundit (installed but **no API authorization today**), ActiveStorage (S3/MinIO/Disk), Administrate admin.

The entire AI layer lives in `app/helpers/openai_helper.rb`:
- **ASR:** `client.audio.translate(model: "whisper-1", file:)` — hardcoded; `translate` **always outputs English** and returns **only `{text}`** (no usage/token block). Reads the in-request upload **tempfile** (`File.open`), not ActiveStorage. Records **zero** usage.
- **Structuring:** `client.chat(model: "gpt-3.5-turbo-1106", tools: [fill_form])` — hardcoded legacy model, **non-strict** function calling, `required: []`. Sums tokens onto the `transcriptions` row.
- Credentials ENV-only; a single memoized global client.
- `FormField#to_json_schema_for_ai` emits a near-core schema **but `multi_select` is wrong**: `{type:'array', enum:[...]}` (enum on the array, no `items`) — rejected by strict engines. Per-field `context` (a live feature) is merged into descriptions via `smart_description`.

Domain: `User → Template → Page(prompt) → FormField`; `Transcription` belongs to user+page; `Domain` maps `fqdn → Template`. Auth: `Api::BaseController` does `ApiToken.find_by(token:)` — plaintext, and **does not apply the model's `active`/`expires_at` scope** (expired/deactivated tokens still authenticate, CWE-613). `Api::V1::TranscriptionsController#create` does `Page.find_by(id:)` with **no ownership check** (cross-account IDOR, CWE-639/862). `ExceptionHandler` renders raw `err.message` to clients (CWE-209).

The flow is **synchronous two-call**: `POST /api/v1/pages/:id/transcriptions` (blocks on Whisper) then `POST /api/v1/transcriptions/:id/generate_completion` (blocks on GPT).

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
| API compatibility | **Greenfield** `/api/v2`. v1 reimplemented as an inline shim onto the new engine, then retired. |
| Output | **Form-fill (schema) + templated clinical notes**, multiple outputs per session. |
| Language | **Form/note outputs are English by default** via the structuring layer. The persisted **Transcript is always source-language** (faithful audit artifact). An **English transcript** is an optional, **separately-metered** output. |
| Diarization | **Not required v1**; data model carries speaker labels for later. |
| Compliance | **No hard constraint v1**; self-hosting must remain possible. |

## 4. Architecture

The API layer never references a model. It calls an **orchestrator** that composes **stages** (ASR, Structuring), each backed by a **provider adapter** resolved from DB config. A `UsageRecorder` is a **pure per-attempt meter**; the **stage** owns fallback.

```
Client (SDK/EMR) ──Bearer msk_live_…──► Api::V2::ScribeSessionsController
                                          auth(digest+active+expiry) → account-scope/authorize
   create: cheap rate-limit/balance check        commit: atomic quota HOLD → enqueue
                                                          │
                                                          ▼
                              ProcessScribeSessionJob (solid_queue)
                                          │
                                  Scribe::Orchestrator  (reads requested outputs)
                                     │                       │
                                  AsrStage             StructuringStage   (or CombinedStage*)
                                     │  (owns try-primary-then-fallback)   *post-v1
                                  Llm::ConfigResolver  (Page → Account → System)
                                     │                       │
                                  Llm::Adapter  (OpenAICompatible | Anthropic | …)
                                     │  .transcribe / .structure → normalized Result+usage
                                  UsageRecorder: one usage_event per physical attempt
                                          │
        OpenAI · Groq · self-hosted Whisper/vLLM · Anthropic · Gemini (openai-compat) …
```

### 4.1 Module layout

```
app/services/llm/
  config.rb            # value object; lazy #api_key accessor (decrypt happens here, not in resolver)
  default_config_provider.rb  # ENV-bootstrap path (no DB rows yet)
  config_resolver.rb   # most-specific-wins resolution → Llm::Config (no decryption)
  result.rb            # { text, structured, model, provider, usage, latency_ms, finish_reason, raw }
  usage.rb             # { input_tokens, output_tokens, total_tokens, audio_seconds, estimated:bool }
  caller.rb            # try-primary-then-fallback; invokes UsageRecorder once per physical attempt
  registry.rb          # provider kind → adapter class
  errors.rb            # Llm::Error: Timeout, RateLimited, BadResponse, SchemaTooComplex, Refused
  adapter.rb           # abstract: #transcribe / #structure; rescues Faraday → Llm::Error
  adapters/
    openai_compatible.rb   # OpenAI, Groq, vLLM, Ollama, LM Studio, self-host (uri_base)
    anthropic.rb           # Claude (can_transcribe=false; no audio endpoint)
    # gemini.rb            # later

app/services/scribe/
  orchestrator.rb      # composes stages from requested outputs + resolved configs
  asr_stage.rb         # audio (from ActiveStorage blob) → Transcript (normalized)
  structuring_stage.rb # transcript + schema/prompt → structured result / note; also translate-mode
  combined_stage.rb    # POST-V1: audio → structured (single multimodal model)
  schema_builder.rb    # Page/FormFields + context → core JSON Schema (single source of truth)
  schema_validator.rb  # json_schemer validate + one bounded repair re-ask

app/services/metering/
  usage_recorder.rb    # pure per-attempt meter: create usage_event, finalize/fail, cost calc
  price_book.rb        # resolve effective ModelPrice / AudioModelPrice at a timestamp
  quota_guard.rb       # atomic ledger HOLD at commit + atomic deduction on finalize
  reservation_sweeper.rb # recurring: expire stale holds / pending events, release budget
```

English-transcript output reuses `structuring_stage` in **translate mode** (metered as `function: structuring`) — no separate code path.

### 4.2 Provider abstraction

**`Llm::Config`** — immutable value object: `provider_kind`, `api_model_id`, `base_url`, `organization_id`, `request_timeout`, `capabilities` (hash), `options`, `fallback` (another `Llm::Config` or nil), and a **lazy `#api_key`** that decrypts on demand (so resolver unit tests need no encryption fixtures).

**`Llm::ConfigResolver.call(function:, page:, account:)`** — finds the most-specific `ModelAssignment` (`Page → Account → System`) for `function ∈ {asr, structuring, combined}`, loads `AiModel` + `AiProvider`, resolves `fallback_ai_model_id` into `config.fallback`, returns a `Llm::Config`. When no DB rows exist, `DefaultConfigProvider` builds the config from ENV. **ENV → Config mapping** (proves "no behavior change" in step 2):

| ENV | Config field |
|---|---|
| `OPENAI_ACCESS_TOKEN` | `api_key` |
| `OPENAI_ORGANIZATION_ID` | `organization_id` |
| (default) | `provider_kind: openai_compatible`, `base_url: https://api.openai.com/v1` |
| (default asr) | `api_model_id: whisper-1` |
| (default structuring) | `api_model_id: gpt-4o-mini` (replaces gpt-3.5-turbo-1106) |

**`Llm::Adapter`** — returns a normalized `Llm::Result` carrying `usage`:
- `#transcribe(audio_io, language:, mode:, diarize:, timestamps:)` — `audio_io` is a local IO with `#path` (the job downloads the blob first). Returns `Result(text:, segments/words/speakers, usage.audio_seconds)`. **`audio_seconds` is derived by the adapter from measured duration (ffprobe / blob metadata), never from a provider usage block** — whisper-1 returns only `{text}`.
- `#structure(messages:, schema:, mode:)` → `Result(structured:, usage.input/output_tokens, finish_reason:)`.

`OpenaiCompatibleAdapter` builds a **per-call** `OpenAI::Client.new(access_token:, uri_base:, request_timeout:)` from the `Llm::Config` — no global client. Same code targets OpenAI/Groq/vLLM/Ollama/self-host by changing `base_url` + `api_model_id`. **"Run your own model"** = `AiProvider(kind: openai_compatible, base_url: "http://host:8000/v1")` + `AiModel(api_model_id: "<whatever>")`; the adapter never validates model names. `AnthropicAdapter` translates the core schema to Anthropic's tool/`output_config` shape; `capabilities.can_transcribe = false`.

**Error mapping:** adapters rescue `Faraday::Error` and re-raise as `Llm::Error` (`429 → RateLimited`, `Faraday::TimeoutError → Timeout`, non-2xx/parse-fail → `BadResponse`) **without** upstream message/headers. Asserted in the adapter contract test. When a provider omits `usage` (some self-hosted), fall back to a local tokenizer estimate flagged `estimated: true`; **never finalize a billable event at zero usage silently**.

**Fallback (single owner):** `Llm::Caller` (used by each stage) owns try-primary → on `Timeout`/`RateLimited`/`BadResponse` try `config.fallback` once, and calls `UsageRecorder` **once per physical attempt**. `UsageRecorder` is a pure meter with no error/config knowledge. A failed primary that still consumed tokens (2xx `BadResponse`/truncation) **is recorded and billed**.

**Security:**
- `AiProvider.api_key` uses Rails 8 `encrypts`. **Prerequisite:** Active Record Encryption keys provisioned (`bin/rails db:encryption:init` → `primary_key`/`deterministic_key`/`key_derivation_salt` in credentials or `ACTIVE_RECORD_ENCRYPTION_*` ENV) in dev/CI/prod before any `AiProvider` read/write, or it raises. Never log decrypted keys.
- The **global** exception handler (not just the OpenAI path) returns `{error:{code:'internal_error', message:<static>, request_id}}`; raw `err.message` goes to logs only.

### 4.3 ASR function

- **Use `audio.transcribe`, not `audio.translate`.** `mode` is explicit: `:transcribe` (source language, portable) or `:translate` (English, whisper-1-only — capability-gated). The persisted Transcript is **always source-language**. English form/note output comes from the structuring layer; an English **transcript** is an opt-in output produced by `structuring_stage` translate-mode (metered).
- Gate ASR providers by `capabilities.can_transcribe`. Self-hosted vLLM/faster-whisper expose `/v1/audio/transcriptions` (works), not `/v1/audio/translations`.
- **Async audio sourcing:** the job re-opens audio from the ActiveStorage blob (`blob.open` → Tempfile) because the request tempfile is gone and `ruby-openai`'s multipart layer needs an IO with `#path` (not a URL). Verify Disk (dev/test) and S3/MinIO (prod) both support `blob.open`.
- **Adapter normalizes:** input (blob/file), per-provider size limits (OpenAI 25MB, Groq 100MB) with ffmpeg silence-boundary chunking for long audio; `language_hint`; `mode`; `diarize`; `timestamps`. Returns `{text, language, segments[], words[], speakers[], duration_seconds, provider, model}`.
- **Billing:** per audio-minute. `audio_seconds` measured independently (ffprobe/blob metadata). Round per the provider's own billing rule, **snapshotted**; chunked audio sums raw seconds then rounds once. Finalized ASR events assert `audio_seconds > 0`.
- **First providers:** OpenAI (`whisper-1`, `gpt-4o-transcribe`), Groq (`whisper-large-v3-turbo`), self-hosted Whisper via `base_url`. Adapter maps requested features → a valid model or drops unsupported options with a logged warning.

### 4.4 Structuring function

- **`SchemaBuilder` is the single source of truth** (not the model method). The 5 field types map to the universal enforced subset:
  `string→{type:string}`, `number→{type:number}`, `boolean→{type:boolean}`, `single_select→{type:string,enum}`, **`multi_select→{type:array, items:{type:string, enum:[...]}}`** (the existing `to_json_schema_for_ai` emits `enum` on the array — wrong — `SchemaBuilder` fixes it; covered by a multi_select test).
  `enum` is enforced everywhere; **`minimum`/`maximum` are NOT** — inject into the field `description` AND validate in Ruby post-call.
- **Per-field `context`** (port of v1 `smart_description`): a per-output `context` map threads through `SchemaBuilder` into field descriptions, preserving the live v1 feature.
- **Prefer `response_format: json_schema` (strict)** over the `fill_form` tool. Use tool-calling only for models flagged `supports_function_calling && !supports_json_schema`.
- **Per-provider transforms** isolated in adapters: OpenAI strict (all props in `required`; optional = `["type","null"]`; `additionalProperties:false`; root object); Anthropic strict (real `required` subset; caps ~24 optional/16 union — **gate large forms away from Anthropic via a size/capability check with auto-fallback to the OpenAI-compatible path; defer split-and-merge behind a flag**, keep 400 detection); Gemini (`responseSchema`+`responseMimeType`; set required/optional explicitly).
- **Normalize optional semantics to nullable-everywhere.**
- **Validate + repair:** branch on `finish_reason`/`stop_reason` **first** (truncation/refusal return 2xx with bad output). Validate against the *full* schema (incl. min/max) with `json_schemer`; on failure one bounded re-ask including the errors.
- **Re-structure path:** structuring can run against an existing stored Transcript, creating structuring-only `usage_events` and **no** ASR event ("re-run without re-billing audio").
- **Notes output:** a `note` output runs the structuring model in free-text mode with a `template_ref` prompt → markdown/text.

### 4.5 Single-model-does-both (POST-V1)

Capability flags (`accepts_audio`, `can_transcribe`, `can_structure`, `supports_json_schema`, `supports_function_calling`, `native_diarization`) ship in v1 and the orchestrator inspects them, but **`CombinedStage` itself is deferred** until a concrete combined-model use case exists (the default cascaded path never exercises it). **Orchestrator selection rule:** a capable `combined` assignment on the Page ⇒ `CombinedStage`; otherwise cascaded (resolve `asr` + `structuring`). A `combined` assignment coexisting with `asr`/`structuring` ⇒ `combined` wins. When CombinedStage lands it must request a `transcript` field inside the schema so the audit artifact is never lost, and bills as `function: combined` (carries both audio_seconds and tokens).

## 5. Data model

**Kept:** `Template`, `Page`, `FormField`. **`transcriptions` is retired only after step 9** (the v1 shim still reads it until then); legacy token sums are backfilled best-effort into `usage_events` as historical rows.

### 5.1 Tenancy & auth
- **`accounts`**: `name`, `status`, `settings jsonb` (rpm/tpm limits), `webhook_secret`, `default_callback_url`. `has_many :users, :api_tokens, :model_assignments, :scribe_sessions, :usage_events`; `has_one :account_credit`.
- **`users`** (changed): add `account_id` (nullable during migration; backfill one account per existing user).
- **`api_tokens`** (changed): add `account_id`, `token_digest` (SHA-256 of a high-entropy token), `token_prefix` (`msk_live_…`), `scopes string[]`. **Migration:** add columns nullable → backfill `token_digest = SHA256(token)` → dual-read (digest then legacy `token`) → `create` reveals plaintext **once**, `show.html.erb` shows only `token_prefix` → drop `token`/NOT NULL/unique/presence **last**.
- **Auth (fix inherited bugs):** lookup by `token_digest`, **then** check `active` + not-expired + scope. Every v2 endpoint scopes by `current_account` (cross-account `:id` ⇒ 404); `page_id`/`template_ref` in bodies must belong to the token's account. Pundit policies + `authorize`/`policy_scope` in every action; the v1 shim gets the same ownership check. Cross-account request tests required.

### 5.2 Model config & catalog (operator-managed)
- **`ai_providers`**: `name`, `kind` (`openai_compatible`/`anthropic`/`gemini`), `base_url`, `encrypted_api_key`, `organization_id`, `request_timeout`, `active`.
- **`ai_models`** (belongs_to provider): `api_model_id`, `display_name`, `capabilities jsonb`, `active`.
- **`model_assignments`**: `scope_type` (`System`/`Account`/`Page`), `scope_id` (null for System), `function` (`asr`/`structuring`/`combined`), `ai_model_id`, `fallback_ai_model_id`, `options jsonb`. Unique `(scope_type, scope_id, function)`.

### 5.3 Scribe domain
- **`scribe_sessions`**: `account_id`, `api_token_id`, `user_id?`, `status` (`created`/`uploading`/`processing`/`completed`/`partial`/`failed`/`expired`), `language`, `mode` (`dictation`/`consultation`), `idempotency_key` (client key, unique per token), `callback_url`, `expires_at`, `error jsonb`. `has_many_attached :audio_files`; `has_one :transcript`; `has_many :scribe_outputs`. **Upload/commit on an expired session ⇒ `session_expired`**; a sweeper expires sessions and purges audio at `expires_at`.
- **`transcripts`**: `scribe_session_id`, `text`, `language`, `duration_seconds`, `provider`, `model`, `segments jsonb`, `words jsonb`, `speakers jsonb`. Always source-language; always persisted.
- **`scribe_outputs`**: `scribe_session_id`, `output_type` (`transcript`/`form`/`note`), `page_id?`, `template_ref?`, `context jsonb`, `status` (`pending`/`success`/`partial`/`failure`), `result jsonb`, `errors jsonb`.

### 5.4 Metering & billing
- **`usage_events`** (one per physical adapter attempt): `account_id`, `api_token_id`, `scribe_session_id?`, `scribe_output_id?`, `function` (`asr`/`structuring`/`combined`), `provider`, `model`, `model_version`, `input_tokens`, `output_tokens`, `total_tokens`, `audio_seconds`, `estimated bool`, `unit_price_input/output/audio_min` (snapshotted), `cost decimal(12,6)`, `currency`, `fx_rate`, `cost_settlement decimal(12,6)`, `latency_ms`, `status` (`pending`/`finalized`/`failed`), `request_id`, `reserved_until`, `dedupe_key`, `updated_at`.
  - **No global unique on a shared idempotency key.** Per-event `dedupe_key = hash(scribe_session_id, function, scribe_output_id, attempt)`, unique within `(api_token_id, dedupe_key)`.
  - Has `updated_at` (rows transition `pending → finalized/failed`; not strictly append-only — `credit_transactions` is the immutable ledger).
  - Indexes: `(account_id, created_at)`, `(account_id, model)`, unique `(api_token_id, dedupe_key)`, `(status, reserved_until)` for the sweeper.
- **`account_usage_daily` / `account_usage_monthly`**: derived rollups, rebuildable.
- **`model_prices`** (versioned): `provider`, `model`, `input_per_million`, `output_per_million`, `currency`, `effective_at`, `deprecated_at`.
- **`audio_model_prices`** (versioned): `provider`, `model`, `price_per_minute`, `currency`, `effective_at`, `deprecated_at`.
- **`account_credits`**: authoritative `balance` (derivable from `SUM(credit_transactions)`); `credit_limit`; `refill_period`. Settlement in a single declared **credit unit** (internal credits or one settlement currency); per-event `fx_rate` + `cost_settlement` normalize mixed-currency provider costs.
- **`credit_transactions`** (immutable ledger): `type` (`hold`/`deduction`/`refund`/`allocation`/`adjustment`), `amount`, `balance_before`, `balance_after`, `usage_event_id?`, `scribe_session_id?`. **Unique `(usage_event_id, type)`** so a retried finalize can't double-deduct.

## 6. Metering & billing flow

1. **Create** (controller): cheap rate-limit + balance-existence check only. No cost-bearing reservation (audio doesn't exist yet, so per-minute cost is unknowable).
2. **Commit** (audio uploaded, duration measurable): take an atomic quota **hold** against the ledger — a single conditional INSERT/UPDATE evaluating `balance − SUM(open holds) − estimate ≥ 0` (closes the concurrent-burst race). Hold carries `reserved_until = session.expires_at`. Then enqueue.
3. **In the job:** **one `usage_event` per physical adapter attempt**, created then finalized **independently**, each with its own `dedupe_key`. The adapter supplies normalized `usage` (tokens for structuring; measured `audio_seconds` for ASR; `estimated:true` fallback if a provider omits usage). Deduction on finalize = one DB transaction inserting a `credit_transactions(deduction)` + conditional `account_credits` UPDATE guarding **both** balance and not-already-applied (`(usage_event_id, type)` unique).
4. **Refund is per usage_event:** only events whose own call failed are refunded; a successful upstream stage is never refunded because a downstream sibling failed. A `partial` session bills successes, refunds failures. The hold is trued-up once all events settle.
5. **Sweeper** (`reservation_sweeper`, recurring): transitions stale `pending` events / open holds past `reserved_until` to `failed`/released; job retry-exhaustion marks its pending events failed in an `ensure`/around callback; reservation is idempotent so retries don't double-reserve.
6. **Rate limiting:** `rack-attack` keyed on **`account_id`** (not the bearer token — N tokens must not get N× the cap), backed by `solid_cache`, emitting `429` + `RateLimit-Limit/Remaining/Reset` (epoch) + `Retry-After`. Per-account TPM/RPM from `accounts.settings`.
7. **Reconciliation:** monthly job diffs `SUM(usage_events.cost_settlement)` per provider vs invoice; alert if delta > ~3%.

## 7. Public API & SDK (v2)

Bearer auth, JSON, `/api/v2`. Error envelope `{error:{code, message, request_id, details}}` with stable codes (`validation_error`, `unauthorized`, `rate_limited`, `session_not_found`, `session_expired`, `audio_upload_failed`, `processing_failed`, `internal_error`).

| Method & path | Purpose |
|---|---|
| `POST /api/v2/scribe_sessions` | Create. Body: `outputs:[{type:transcript[,translate]}|{type:form,page_id,context}|{type:note,template_ref}]`, `language_hint`, `mode`, `callback_url`. Returns `id`, `status:created`, `expires_at`, upload target. Decoupled from a single page. |
| `POST /api/v2/scribe_sessions/:id/audio` | Upload audio — **one canonical encoding** (multipart form-data), hard max size enforced at ingress (before any reservation); presigned-S3 direct variant sets `content-length-range`. Chunk `:seq` ordering reserved for later. |
| `POST /api/v2/scribe_sessions/:id/commit` | Canonical **billable, idempotent** op. `202 Accepted`, `status:processing`, atomic hold, enqueues. |
| `GET /api/v2/scribe_sessions/:id` | Poll: `200` done · `202` processing · `206` partial. Per-output `status` + `errors`. |
| `GET /api/v2/scribe_sessions` | List (account-scoped). |
| `GET /api/v2/config` | Discovery: languages, templates, limits (account-scoped). |
| `GET /api/v2/usage` | Account usage summary (rollups). |

**Idempotency:** dedicated store `(api_token, key, request_fingerprint, response, expires_at)` — **not** `usage_events`. **Commit** is the canonical idempotent billable op; the reservation is created idempotently within one transaction. Payload hashed → `409` on conflicting payload for the same key. ~24h retention.

**Webhooks (primary) + polling (fallback):** on completion POST a **PHI-light** body — explicit allowlist: `session_id`, output ids, statuses, timestamps, counts, and a signed **`delivery_id`** (no transcript text or field values; full results via authenticated GET). Header `X-Medispeak-Signature: t=<unix>,v1=<hex>` where `v1=HMAC-SHA256(secret, "<t>.<raw_body>")` — sign the **raw** body; constant-time verify; reject future-dated `t`; ~5-min replay window **plus** consumer dedupe on `delivery_id`; at-least-once with exponential backoff. A test asserts no result content in the body.

**PHI:** signed audio URLs only — concrete TTL ≤ 5 min, single-object scope (replaces v1's `url_for(audio_file)`).

**SDK shape (TS + Ruby):** mirror REST 1:1, plus one-call `client.scribe.transcribe(file, outputs:[…])` (hides create→upload→commit→poll) and granular methods.

**v1 compatibility (shim):** v1 endpoints reimplemented to run the orchestrator **inline** (synchronous, preserving blocking semantics) and re-assemble the legacy response shape. Requires an explicit **old-column → new-source field map** + a **status-enum crosswalk** (4-value → 7-value). v1 per-field `context` is threaded through. Metering/quota now apply (a behavior change for existing integrators — call out). A **golden v1 response-body test is pinned before refactoring**, plus the cross-account ownership fix.

## 8. Migration / sequencing

**Step 0 / smallest first PR — harness + safety:** stand up the test harness (`webmock` + a mocking lib + factories; switch test env to **inline Active Job** + a **memory cache** store); fix the safety leaks (scrub global `err.message`, add `request_id`); pin the **v1 golden-response baseline test**. No behavior change to the AI path yet.

1. **ASR correctness:** `audio.translate → audio.transcribe` with explicit `mode` + `language`. **Default `mode: :translate` to preserve current English output until step 3** (so this is genuinely non-breaking), or ship as a documented breaking change — not both silently.
2. **Adapter + resolver seam:** extract `OpenaiHelper` → `Llm::OpenaiCompatibleAdapter` + `Llm::Caller` returning normalized `Result`; `Llm::Config` + `ConfigResolver` + `DefaultConfigProvider` (ENV defaults per the §4.2 table). Chat and audio are separate adapter methods. No behavior change.
3. **Structuring reliability:** drop `gpt-3.5-turbo-1106`; `SchemaBuilder` (fix multi_select + context); `response_format json_schema` + `strict`; `json_schemer` validate+repair; `finish_reason` branching; optional→nullable. Flip step-1 English default to source-language now that structuring produces English.
4. **Background jobs:** finish `solid_queue` setup (enable adapter in dev/test, `bin/rails db:prepare` the queue DB, **remove unused delayed_job**); `ProcessScribeSessionJob`; audio re-sourced via `blob.open`.
5. **Tenancy + metering schema:** `Account` + `api_tokens.account_id` + hashed tokens (migration per §5.1) + auth active/expiry fix; `usage_events` + price book + `UsageRecorder`; backfill legacy token sums best-effort. Capture `audio_seconds`. (Keep `transcriptions`.)
6. **DB-backed config:** **provision Active Record Encryption keys first**; `ai_providers`/`ai_models`/`model_assignments` with `encrypts`; resolver reads DB (most-specific) with ENV fallback. "Run your own model" works via a config row + `base_url`.
7. **Capability flags + 2nd provider:** add flags; `AnthropicAdapter` (proves the abstraction; unlocks Claude structuring + mix-and-match). CombinedStage stays deferred.
8. **Quotas + rate limiting:** `rack-attack` (account-keyed) + credit ledger with atomic hold/deduction + `reservation_sweeper`.
9. **New async v2 API + SDK:** `scribe_sessions` resource, idempotency store, webhooks; v1 shimmed inline; deprecate v1. **Retire `transcriptions` only after this lands.**
10. **Optional gateway:** LiteLLM only if per-tenant budget enforcement at scale demands it.

**New gems (pin versions):** `rack-attack`, `json_schemer`, an Anthropic client gem, `webmock` (test), a mocking lib + `factory_bot_rails` (test). Note `rack-attack` tests need a real cache store.

## 9. Testing strategy

The Minitest harness is **net-new** (only an empty `user_test.rb` today). Add `webmock` + a mocking lib + factories; test env uses **inline Active Job** and a **memory cache** store.
- **Adapter contract tests:** shared module run against every adapter — stubbed provider response → correct normalized `Result` + `usage`; Faraday→`Llm::Error` mapping; usage-missing → `estimated:true`.
- **Resolver tests:** Page→Account→System precedence; ENV fallback; fallback-config resolution (no encryption fixtures needed — lazy `api_key`).
- **SchemaBuilder/Validator:** all 5 field types (esp. **multi_select `items.enum`**); context→description; optional→nullable; min/max in description + post-validation; one-shot repair.
- **Orchestrator (fake stages):** cascaded composition; per-output status isolation (one failure ⇒ `partial`).
- **Metering:** hold→event→finalize lifecycle; cost math (token & per-minute, rounding); atomic deduction + `(usage_event_id,type)` uniqueness under simulated concurrency; per-event refund; sweeper releasing orphaned holds; dedupe-key behavior.
- **API request tests:** lifecycle status codes (`201/202/200/206`); idempotency replay + `409`; rate-limit `429` + headers (account-keyed); HMAC webhook (raw-body, constant-time, future-`t` reject, `delivery_id` dedupe, no PHI in body); **cross-account authorization** (404/forbidden).
- **v1 shim:** golden-response baseline; `context` still influences schema; ownership fix.

## 10. Risks & open items

- **No public benchmark covers Indian medical audio.** Run an empirical ASR bake-off (Sarvam vs Deepgram Nova-3 Medical vs gpt-4o-transcribe-with-prompt vs self-hosted Whisper) on real audio before defaulting a model. Ops task, not a code blocker.
- **Anthropic strict schema caps** (~24 optional / 16 union) — large forms auto-fallback to OpenAI-compatible; split-extraction deferred behind a flag.
- **Audio duration measurement** must be reliable (ffprobe/blob metadata) or ASR under-bills.
- **Credit race-safety** depends on atomic conditional hold + deduction, not ledger rows alone.
- **Mixed-currency** provider costs require `fx_rate`/`cost_settlement`; declare the credit unit before billing real customers.
- **v1 retirement:** confirm integrator dependence before dropping v1; the inline shim covers the window.
