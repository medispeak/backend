# Model-Agnostic Configuration

Medispeak runs **any model for ASR** (speech to text) and **any model for
structuring** (text to form/note), in **any combination**, including your own
self-hosted models. Configuration is runtime and lives in the database, resolved
most-specific-first per page, then account, then system, with an ENV fallback.

This guide explains the configuration models and how to wire up providers,
models, and assignments — including running your own model and mix-and-match
setups.

---

## The configuration models

### `AiProvider`

A provider endpoint and its credentials.

| Attribute         | Notes |
|-------------------|-------|
| `name`            | Human label. |
| `kind`            | `openai_compatible`, `anthropic`, or `gemini`. |
| `base_url`        | The endpoint host root (see note below). |
| `api_key`         | Active Record **encrypted** column. |
| `organization_id` | Optional (OpenAI org id). |
| `request_timeout` | Seconds (default 120 when nil). |
| `active`          | Boolean; `AiProvider.active` scope. |

**`base_url` semantics:**

- For `openai_compatible`, `base_url` is the **host root** and the ruby-openai
  client appends `/v1`. So OpenAI is `https://api.openai.com/`, OpenRouter is
  `https://openrouter.ai/api/`, and a self-hosted server is
  `http://your-host:8000/`. (If your endpoint is already rooted at `/v1`, set
  `options: { api_version: "" }` on the assignment so nothing is appended.)
- For `anthropic`, the adapter POSTs to `base_url + "/v1/messages"`, so
  `base_url` is `https://api.anthropic.com`.

> "Run your own model" is simply an `openai_compatible` provider whose `base_url`
> points at your server, e.g. `http://localhost:8000/`.

### `AiModel`

A model offered by a provider (`belongs_to :ai_provider`).

| Attribute      | Notes |
|----------------|-------|
| `api_model_id` | The exact id sent to the provider (e.g. `whisper-1`, `gpt-4o-mini`, `claude-3-5-sonnet-latest`). The adapter never validates this. |
| `display_name` | Human label. |
| `capabilities` | JSONB capability flags (see below). |
| `active`       | Boolean. |

**Capability flags** (`capabilities` JSONB; checked via `AiModel#capability?`):

| Flag                     | Meaning |
|--------------------------|---------|
| `accepts_audio`          | Model can take audio input. |
| `can_transcribe`         | Model exposes audio transcription (ASR). |
| `can_structure`          | Model can produce structured output. |
| `supports_json_schema`   | Supports strict `response_format: json_schema`. When true the OpenAI-compatible adapter sends a strict JSON schema; otherwise it relies on plain chat output. |
| `supports_function_calling` | Supports tool/function calling. |
| `native_diarization`     | Returns speaker labels natively. |

> The Anthropic adapter has **no audio endpoint** — `#transcribe` raises. Models
> on an `anthropic` provider must have `can_transcribe: false` and only be used
> for structuring.

### `ModelAssignment`

Binds a function to a model at a scope.

| Attribute           | Notes |
|---------------------|-------|
| `scope_type`        | `System`, `Account`, or `Page`. |
| `scope_id`          | The account/page id; **nil for System**. |
| `function`          | `asr`, `structuring`, or `combined`. |
| `ai_model`          | The model to use. |
| `fallback_ai_model` | Optional model used on a transient failure of the primary. |
| `options`           | JSONB passed to the adapter (e.g. `max_tokens`, `api_version`). |

Unique on `(scope_type, scope_id, function)`.

---

## Resolution order

`Llm::ConfigResolver.call(function:, page:, account:)` finds the most-specific
assignment:

```
Page  ─►  Account  ─►  System  ─►  ENV defaults (DefaultConfigProvider)
```

If no `ModelAssignment` matches at any scope, the resolver falls back to
`Llm::DefaultConfigProvider`, which builds an OpenAI config from ENV:

| ENV                      | Maps to |
|--------------------------|---------|
| `OPENAI_ACCESS_TOKEN`    | `api_key` |
| `OPENAI_ORGANIZATION_ID` | `organization_id` |
| (default)                | `openai_compatible` @ `https://api.openai.com/` |

Default models from `DefaultConfigProvider`:

- `asr` → `whisper-1`
- `structuring` → `gpt-4o-mini`

This is the backward-compatible bootstrap path: with no DB rows and just
`OPENAI_ACCESS_TOKEN` set, the system behaves like the original OpenAI-only
deployment.

---

## (a) Add a provider + model + assignment

### Via seeds / console

```ruby
provider = AiProvider.create!(
  name: "OpenAI",
  kind: "openai_compatible",
  base_url: "https://api.openai.com/",
  api_key: ENV["OPENAI_ACCESS_TOKEN"],
  organization_id: ENV["OPENAI_ORGANIZATION_ID"],
  active: true
)

asr_model = provider.ai_models.create!(
  api_model_id: "whisper-1",
  display_name: "Whisper v1",
  capabilities: { accepts_audio: true, can_transcribe: true },
  active: true
)

structuring_model = provider.ai_models.create!(
  api_model_id: "gpt-4o-mini",
  display_name: "GPT-4o mini",
  capabilities: {
    can_structure: true,
    supports_json_schema: true,
    supports_function_calling: true
  },
  active: true
)

# System defaults (scope_id is nil for System).
ModelAssignment.create!(scope_type: "System", scope_id: nil, function: "asr",
                        ai_model: asr_model)
ModelAssignment.create!(scope_type: "System", scope_id: nil, function: "structuring",
                        ai_model: structuring_model)
```

To override for one account or page, create an assignment with
`scope_type: "Account"` / `"Page"` and the corresponding `scope_id`.

> **Encryption prerequisite:** because `AiProvider.api_key` uses Active Record
> Encryption, the encryption keys must be provisioned before reading/writing any
> provider (`bin/rails db:encryption:init` → set `primary_key`,
> `deterministic_key`, `key_derivation_salt` in credentials, or the
> `ACTIVE_RECORD_ENCRYPTION_*` ENV vars).

### Via the admin UI

The admin uses the Administrate gem. Providers, models, and assignments are
managed through the admin dashboards/controllers under `app/dashboards/` and
`app/controllers/admin/` (routed under `namespace :admin`). Create the provider
first, then its models, then the assignment binding a function to a model at the
desired scope.

---

## (b) Run your own model (self-hosted, OpenAI-compatible)

Stand up an OpenAI-compatible server, then point a provider at it.

Examples:

```bash
# vLLM serving Whisper for ASR
vllm serve openai/whisper-large-v3            # exposes /v1/audio/transcriptions

# or faster-whisper-server (OpenAI-compatible ASR)
# or Ollama for chat/structuring (OpenAI-compatible at http://localhost:11434/)
```

Then create the config row:

```ruby
selfhost = AiProvider.create!(
  name: "Self-hosted Whisper",
  kind: "openai_compatible",
  base_url: "http://your-host:8000/",   # host root; client appends /v1
  api_key: "not-needed-or-your-gateway-key",
  active: true
)

whisper = selfhost.ai_models.create!(
  api_model_id: "whisper-large-v3",     # whatever your server exposes
  display_name: "Self-hosted Whisper large v3",
  capabilities: { accepts_audio: true, can_transcribe: true },
  active: true
)

ModelAssignment.create!(scope_type: "System", scope_id: nil,
                        function: "asr", ai_model: whisper)
```

The adapter never validates model names — it sends `api_model_id` straight to
your endpoint. Self-hosted Whisper exposes `/v1/audio/transcriptions`, which is
exactly what the transcribe path calls.

---

## (c) Mix-and-match examples

ASR and structuring are independently assigned, so you can mix providers freely.

### Open-source structuring via OpenRouter + OpenAI Whisper ASR

```ruby
openai = AiProvider.create!(name: "OpenAI", kind: "openai_compatible",
                            base_url: "https://api.openai.com/",
                            api_key: ENV["OPENAI_ACCESS_TOKEN"], active: true)
whisper = openai.ai_models.create!(api_model_id: "whisper-1",
                                   capabilities: { accepts_audio: true, can_transcribe: true },
                                   active: true)

openrouter = AiProvider.create!(name: "OpenRouter", kind: "openai_compatible",
                                base_url: "https://openrouter.ai/api/",
                                api_key: ENV["OPENROUTER_API_KEY"], active: true)
oss = openrouter.ai_models.create!(api_model_id: "meta-llama/llama-3.1-70b-instruct",
                                   capabilities: { can_structure: true, supports_json_schema: true },
                                   active: true)

ModelAssignment.create!(scope_type: "System", function: "asr",        ai_model: whisper)
ModelAssignment.create!(scope_type: "System", function: "structuring", ai_model: oss)
```

### Claude (Anthropic) structuring + self-hosted Whisper ASR

```ruby
anthropic = AiProvider.create!(name: "Anthropic", kind: "anthropic",
                               base_url: "https://api.anthropic.com",
                               api_key: ENV["ANTHROPIC_API_KEY"], active: true)
claude = anthropic.ai_models.create!(api_model_id: "claude-3-5-sonnet-latest",
                                     capabilities: { can_structure: true, can_transcribe: false },
                                     active: true)

selfhost = AiProvider.create!(name: "Self-hosted Whisper", kind: "openai_compatible",
                              base_url: "http://your-host:8000/", api_key: "x", active: true)
whisper = selfhost.ai_models.create!(api_model_id: "whisper-large-v3",
                                     capabilities: { accepts_audio: true, can_transcribe: true },
                                     active: true)

ModelAssignment.create!(scope_type: "System", function: "asr",         ai_model: whisper)
ModelAssignment.create!(scope_type: "System", function: "structuring", ai_model: claude)
```

### Important constraints

- **OpenRouter is chat-only — no audio.** Use it (or Anthropic) only for the
  `structuring` function. Do not assign it to `asr`.
- **Open-source ASR must be a self-hosted or Groq-style OpenAI-compatible
  endpoint** that exposes `/v1/audio/transcriptions` (vLLM, faster-whisper,
  Groq). Anthropic and OpenRouter cannot perform ASR.
- **Anthropic models must have `can_transcribe: false`** — the Anthropic adapter
  raises on any transcribe call.

---

## Fallback

Set `fallback_ai_model` on an assignment to retry once on a transient failure
(`Llm::Timeout`, `Llm::RateLimited`, `Llm::BadResponse`). `Llm::Caller` owns this
policy and records one usage event per physical attempt. Refusals are **not**
retried.

See [architecture.md](./architecture.md) for how these pieces fit together and
[metering-and-billing.md](./metering-and-billing.md) for how each attempt is
priced.
