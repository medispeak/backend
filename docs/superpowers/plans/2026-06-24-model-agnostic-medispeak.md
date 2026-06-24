# Model-Agnostic Medispeak — Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make ASR and Structuring model-agnostic (any provider for each, incl. self-hosted), runtime-configurable per template/page, behind an async metered multi-tenant API.

**Architecture:** A thin in-process `Llm::` adapter seam (Config → Resolver → Adapter → normalized Result), composed by a `Scribe::Orchestrator` into ASR + Structuring stages, with a `Metering::UsageRecorder` wrapping every call. See the design spec: `docs/superpowers/specs/2026-06-24-model-agnostic-medispeak-design.md`.

**Tech Stack:** Rails 8, PostgreSQL, `ruby-openai` (per-call `uri_base`), `solid_queue`, ActiveStorage, Minitest + `webmock`, `json_schemer`, `rack-attack`.

**Environment note:** Dev/test runs via docker-compose (no local `.env`; Postgres is containerized). Commands below assume the app's docker env or a configured `.env`. Pure-Ruby unit tests (POROs + webmock) run without a database; model/request/migration tasks require the test DB.

---

## File structure

```
app/services/llm/
  config.rb              # value object + lazy #api_key
  usage.rb               # Struct: input/output/total tokens, audio_seconds, estimated
  result.rb              # Struct: text, structured, model, provider, usage, latency_ms, finish_reason, raw
  errors.rb              # Llm::Error and subclasses
  default_config_provider.rb  # ENV-bootstrap Llm::Config (no DB)
  config_resolver.rb     # Page→Account→System → Llm::Config (DB; falls back to provider)
  registry.rb            # provider_kind → adapter class
  caller.rb              # try-primary-then-fallback; one UsageRecorder call per attempt
  adapter.rb             # abstract base; Faraday→Llm::Error mapping
  adapters/openai_compatible.rb
  adapters/anthropic.rb  # phase 7

app/services/scribe/
  schema_builder.rb      # Page/FormFields + context → core JSON Schema
  schema_validator.rb    # json_schemer validate + one repair
  orchestrator.rb        # phase 4+
  asr_stage.rb           # phase 4+
  structuring_stage.rb   # phase 4+

app/services/metering/    # phase 5+
  usage_recorder.rb
  price_book.rb
  quota_guard.rb
  reservation_sweeper.rb

app/controllers/concerns/exception_handler.rb   # MODIFY (scrub messages)
app/controllers/api/base_controller.rb          # MODIFY (auth active/expiry + account scope)
app/helpers/openai_helper.rb                    # MODIFY → delegate to Llm seam, then remove
```

---

## Roadmap (chunks)

- **Chunk 1 — Harness + safety (Phase 0–1):** test harness, scrub error leaks, ASR `translate→transcribe` with explicit `mode`. *(detailed below)*
- **Chunk 2 — Adapter seam (Phase 2):** `Llm::Config/Result/Usage/Errors/Adapter/OpenaiCompatibleAdapter/Caller/Resolver`; refactor `OpenaiHelper` to delegate. *(detailed below)*
- **Chunk 3 — Structuring reliability (Phase 3):** `SchemaBuilder` (fix multi_select + context), `response_format json_schema` strict, `json_schemer` validate+repair, finish_reason branching. *(detailed below)*
- **Chunk 4 — Background jobs (Phase 4):** solid_queue setup, remove delayed_job, `ProcessScribeSessionJob`, `blob.open` audio sourcing.
- **Chunk 5 — Tenancy + metering schema (Phase 5):** `Account`, hashed tokens + auth fix, `usage_events` + price book + `UsageRecorder`.
- **Chunk 6 — DB-backed config (Phase 6):** AR Encryption keys, `ai_providers/ai_models/model_assignments`, resolver reads DB.
- **Chunk 7 — Capability flags + Anthropic (Phase 7).**
- **Chunk 8 — Quotas + rate limiting (Phase 8):** rack-attack (account-keyed), credit ledger, sweeper.
- **Chunk 9 — v2 API + SDK (Phase 9):** scribe_sessions, idempotency store, webhooks, v1 inline shim, retire `transcriptions`.

Chunks 4–9 are expanded into bite-sized tasks when reached (each ≤1000 lines, plan-reviewed before execution). Chunks 1–3 follow.

---

## Chunk 1: Harness + safety

### Task 1.1: Test harness gems

**Files:** Modify `Gemfile`; Modify `config/environments/test.rb`

- [ ] **Step 1:** Add to the `:test` group in `Gemfile`:
```ruby
group :test do
  gem "webmock", "~> 3.24"
  gem "mocha", "~> 2.7"
  gem "factory_bot_rails", "~> 6.4"
end
```
- [ ] **Step 2:** In `config/environments/test.rb` set deterministic infra:
```ruby
config.active_job.queue_adapter = :inline
config.cache_store = :memory_store
```
- [ ] **Step 3:** In `test/test_helper.rb` add WebMock + Mocha:
```ruby
require "webmock/minitest"
require "mocha/minitest"
WebMock.disable_net_connect!(allow_localhost: true)
```
- [ ] **Step 4:** Run `bundle install`. Expected: resolves with new gems.
- [ ] **Step 5:** Commit: `chore(test): add webmock/mocha/factory_bot + deterministic test env`

### Task 1.2: Scrub error messages (global + OpenAI path)

**Files:** Modify `app/controllers/concerns/exception_handler.rb`; Test `test/controllers/concerns/exception_handler_test.rb`

- [ ] **Step 1: Failing test** — an uncaught exception renders a static message + `request_id`, never `err.message`:
```ruby
# build a throwaway controller including ExceptionHandler, raise StandardError.new("SECRET leak")
# assert response code internal_error, body message does NOT include "SECRET leak", includes a request_id
```
- [ ] **Step 2:** Run: `bin/rails test test/controllers/concerns/exception_handler_test.rb` → FAIL.
- [ ] **Step 3:** Modify `handle_uncaught_error` to render a static message and a `request_id` (use `request.request_id`), logging the real detail server-side:
```ruby
def handle_uncaught_error(err)
  log_error(err)
  render json: { error: { code: "internal_error",
                          message: "An unexpected error occurred.",
                          request_id: request.request_id } },
         status: :internal_server_error
end
```
- [ ] **Step 4:** Run test → PASS.
- [ ] **Step 5:** Commit: `fix(security): stop leaking exception messages to API clients (CWE-209)`

### Task 1.3: ASR `translate → transcribe` with explicit mode

**Files:** Modify `app/helpers/openai_helper.rb`; Test `test/helpers/openai_helper_test.rb`

- [ ] **Step 1: Failing test** — stub the OpenAI transcriptions endpoint with WebMock; assert `ai_transcribe(file, mode: :transcribe, language: "hi")` calls `/v1/audio/transcriptions` (not `/translations`) and returns text.
- [ ] **Step 2:** Run → FAIL.
- [ ] **Step 3:** Replace `ai_transcribe`:
```ruby
def ai_transcribe(file, mode: :translate, language: nil)
  params = { model: "whisper-1", file: File.open(file) }
  params[:language] = language if language.present? && mode == :transcribe
  response = mode == :transcribe ? client.audio.transcribe(parameters: params)
                                 : client.audio.translate(parameters: params)
  response["text"]
rescue Faraday::Error => e
  handle_openai_error(e)
end
```
> Default `mode: :translate` preserves current English output until Chunk 3 lands structuring-layer English; flip to `:transcribe` in Task 3.x.
- [ ] **Step 4:** Run → PASS.
- [ ] **Step 5:** Commit: `feat(asr): support explicit transcribe/translate mode + language`

### Task 1.4: Pin the v1 golden response (baseline before refactor)

**Files:** Test `test/integration/api/v1/transcriptions_golden_test.rb`; `test/factories/*` as needed

- [ ] **Step 1:** With WebMock stubbing OpenAI transcribe + chat, drive `POST /api/v1/pages/:id/transcriptions` then `POST /api/v1/transcriptions/:id/generate_completion`; snapshot the exact response keys/shape (status enum values, `ai_response`, token fields, `audio_file_url`, `title`).
- [ ] **Step 2:** Run → PASS (captures current contract).
- [ ] **Step 3:** Commit: `test(v1): pin golden response contract before refactor`

> Requires the test DB. If unavailable in this environment, mark Task 1.4 BLOCKED-ON-DB and run it in docker before Chunk 9's shim work.

---

## Chunk 2: Adapter seam (no behavior change)

### Task 2.1: Value objects — `Usage`, `Result`, `Errors`

**Files:** Create `app/services/llm/usage.rb`, `result.rb`, `errors.rb`; Test `test/services/llm/value_objects_test.rb`

- [ ] **Step 1: Failing test** — `Llm::Usage.new(input_tokens: 10, output_tokens: 5).total_tokens == 15`; `Llm::Result` carries `text/usage/provider`; `Llm::RateLimited < Llm::Error`.
- [ ] **Step 2:** Run → FAIL.
- [ ] **Step 3:** Implement:
```ruby
module Llm
  Usage = Struct.new(:input_tokens, :output_tokens, :audio_seconds, :estimated, keyword_init: true) do
    def initialize(**a) = super(**{ input_tokens: 0, output_tokens: 0, audio_seconds: 0, estimated: false }.merge(a))
    def total_tokens = input_tokens.to_i + output_tokens.to_i
  end
  Result = Struct.new(:text, :structured, :model, :provider, :usage, :latency_ms, :finish_reason, :raw, keyword_init: true)
end
# errors.rb
module Llm
  class Error < StandardError; end
  class Timeout < Error; end
  class RateLimited < Error; end
  class BadResponse < Error; end
  class SchemaTooComplex < Error; end
  class Refused < Error; end
end
```
- [ ] **Step 4:** Run → PASS. **Step 5:** Commit: `feat(llm): add Usage/Result/Errors value objects`

### Task 2.2: `Llm::Config` + `DefaultConfigProvider`

**Files:** Create `app/services/llm/config.rb`, `default_config_provider.rb`; Test `test/services/llm/default_config_provider_test.rb`

- [ ] **Step 1: Failing test** — with ENV `OPENAI_ACCESS_TOKEN=sk-x`, `Llm::DefaultConfigProvider.call(function: :structuring)` returns a `Config` with `provider_kind: :openai_compatible`, `base_url` openai, `api_model_id: "gpt-4o-mini"`, and `#api_key == "sk-x"`.
- [ ] **Step 2:** Run → FAIL.
- [ ] **Step 3:** Implement `Config` (keyword_init Struct; `api_key` lazy via a block or stored token) and `DefaultConfigProvider` mapping the ENV table from spec §4.2 (asr→whisper-1 translate default, structuring→gpt-4o-mini). `api_key` reads ENV at call time.
- [ ] **Step 4:** Run → PASS. **Step 5:** Commit: `feat(llm): add Config + ENV-default provider`

### Task 2.3: `Adapter` base + `OpenaiCompatibleAdapter` (transcribe)

**Files:** Create `app/services/llm/adapter.rb`, `app/services/llm/adapters/openai_compatible.rb`; Test `test/services/llm/adapters/openai_compatible_test.rb`

- [ ] **Step 1: Failing test (WebMock)** — adapter built from a `Config` calls `POST {base_url}/audio/transcriptions`, returns `Llm::Result` with `text` and `usage.audio_seconds` measured from the input (stub duration), `provider`, `model`. A `429` stub raises `Llm::RateLimited`; a timeout raises `Llm::Timeout`.
- [ ] **Step 2:** Run → FAIL.
- [ ] **Step 3:** Implement: build a per-call `OpenAI::Client.new(access_token: config.api_key, uri_base: config.base_url, request_timeout: config.request_timeout)`; `#transcribe` uses `client.audio.transcribe`; measure `audio_seconds` via a `Scribe::AudioDuration` helper (ffprobe/blob metadata; here from file). Rescue `Faraday::Error` → map to `Llm::*`.
- [ ] **Step 4:** Run → PASS. **Step 5:** Commit: `feat(llm): OpenAI-compatible adapter (transcribe) with normalized result`

### Task 2.4: `OpenaiCompatibleAdapter#structure`

**Files:** Modify adapter; Test same file

- [ ] **Step 1: Failing test** — `#structure(messages:, schema:)` calls `/chat/completions` with `response_format: {type: "json_schema", json_schema: {strict: true, schema:}}`; returns `Result` with `structured` (parsed) + `usage` from `response["usage"]` + `finish_reason`.
- [ ] **Step 2:** Run → FAIL. **Step 3:** Implement (prefer json_schema; tool-calling path behind a capability flag, added Chunk 7). **Step 4:** PASS. **Step 5:** Commit: `feat(llm): OpenAI-compatible adapter (structure) via json_schema`

### Task 2.5: `Registry` + `Caller` (fallback)

**Files:** Create `app/services/llm/registry.rb`, `app/services/llm/caller.rb`; Test `test/services/llm/caller_test.rb`

- [ ] **Step 1: Failing test** — `Caller.transcribe(config)` calls the primary adapter; when primary raises `Llm::RateLimited` and `config.fallback` is set, it calls the fallback once and returns its result; with no fallback it re-raises.
- [ ] **Step 2:** Run → FAIL. **Step 3:** Implement `Registry.for(kind)` + `Caller` try/rescue. (UsageRecorder hook added Chunk 5 — for now Caller just returns the Result.) **Step 4:** PASS. **Step 5:** Commit: `feat(llm): registry + caller with single-fallback`

### Task 2.6: Refactor `OpenaiHelper` to delegate

**Files:** Modify `app/helpers/openai_helper.rb`; run Task 1.4 golden test

- [ ] **Step 1:** Re-point `ai_transcribe` and `ai_generate_completion` to build a `DefaultConfigProvider` config and call `Llm::Caller`. Keep method signatures and the `transcriptions` token-sum behavior identical.
- [ ] **Step 2:** Run the v1 golden test (Task 1.4) → PASS (no contract change). Run `bin/rails test` → green.
- [ ] **Step 3:** Commit: `refactor(ai): route OpenaiHelper through Llm adapter seam`

---

## Chunk 3: Structuring reliability

### Task 3.1: `Scribe::SchemaBuilder` (fix multi_select + context)

**Files:** Create `app/services/scribe/schema_builder.rb`; Test `test/services/scribe/schema_builder_test.rb`

- [ ] **Step 1: Failing test** — for a page with one of each field type, builder returns a core JSON Schema where:
  - `multi_select → {type:"array", items:{type:"string", enum:[...]}}` (NOT enum on the array),
  - `single_select → {type:"string", enum:[...]}`,
  - `number` min/max appear in `description` (not as `minimum`/`maximum`),
  - a passed `context[title]` is appended to that field's `description`,
  - optional fields are nullable (`["string","null"]`) and all keys are in `required` (OpenAI strict form).
- [ ] **Step 2:** Run → FAIL.
- [ ] **Step 3:** Implement `SchemaBuilder.new(page, context:).call`, building per-field schema from `FormField` attributes (do NOT reuse the buggy `to_json_schema_for_ai` for multi_select). Use POROs / non-persisted `FormField.new` so the test needs no DB where possible.
- [ ] **Step 4:** Run → PASS. **Step 5:** Commit: `feat(structuring): SchemaBuilder fixes multi_select shape + context`

### Task 3.2: `Scribe::SchemaValidator` (validate + one repair)

**Files:** Create `app/services/scribe/schema_validator.rb`; add `gem "json_schemer"`; Test `test/services/scribe/schema_validator_test.rb`

- [ ] **Step 1: Failing test** — valid payload → `{valid: true}`; payload violating an enum/min → `{valid:false, errors:[...]}`; a `repair` block is invoked once with the errors and its corrected output re-validated.
- [ ] **Step 2:** Run → FAIL. **Step 3:** Implement with `JSONSchemer.schema(full_schema)`; `validate_and_repair(payload) { |errors| ... }` does exactly one re-ask. **Step 4:** PASS. **Step 5:** Commit: `feat(structuring): json_schemer validate + single repair`

### Task 3.3: Wire structuring through json_schema + finish_reason + English default

**Files:** Modify `app/helpers/openai_helper.rb` (or a `Scribe::StructuringStage` if extracted); Tests updated

- [ ] **Step 1: Failing test** — structuring uses `SchemaBuilder` + adapter `#structure` (json_schema strict); branches on `finish_reason` (`length`/refusal → error, not blind parse); persists `ai_response`; default model is `gpt-4o-mini` (not `gpt-3.5-turbo-1106`).
- [ ] **Step 2:** Run → FAIL. **Step 3:** Implement; then flip Task 1.3 ASR default to `mode: :transcribe` (source language) since structuring now yields English output. Update the golden test's expectations intentionally (documented contract change for transcript language) OR keep translate default if v1 English transcript must be preserved — decide per the spec §8 step 1/3 note.
- [ ] **Step 4:** Run full suite → green. **Step 5:** Commit: `feat(structuring): strict json_schema + finish_reason guard; drop gpt-3.5`

---

## Verification checklist (per chunk)

- `bin/rails test` green (or pure-Ruby subset where DB unavailable).
- `bundle exec rubocop` clean on touched files (repo uses rubocop-rails-omakase).
- `ruby -c` on every new file.
- v1 golden test unchanged across Chunk 2 (proves no contract drift).

## Risks / notes
- Tasks 1.4 and any model/request test need the test DB (docker). Pure-Ruby tasks (2.1–2.5, 3.1–3.2) run without it.
- Audio duration measurement needs ffprobe available in dev/CI/prod images.
- Default structuring model `gpt-4o-mini` requires an OpenAI key supporting json_schema; for self-host, capability flags (Chunk 7) gate json_schema vs tool-calling.
