# Plan 026: Realtime voice (OpenAI) + Sarvam AI (Indic STT / translate / code-mix)

> **Status: SHIPPED (backend + SDK).** Backend deployed; SDK bumped to 0.3.0
> (publish pending). This is the design + enablement record. Built 2026-07-12.

## What shipped

### 1. Sarvam AI as an ASR provider (backend-only — no SDK/FE change)

Sarvam beats Whisper on Malayalam/Hindi/code-mix and can transcribe OR
translate-to-English in ONE call. New `Llm::Adapters::Sarvam` (provider kind
`sarvam`) posts to `https://api.sarvam.ai/speech-to-text` with the
`api-subscription-key` header. The `saaras:v3` model's `mode` param does it all:

| our config | Sarvam `mode` | result |
|------------|---------------|--------|
| `asr_mode: :transcribe` (default) | `transcribe` | source language |
| `asr_mode: :translate` | `translate` | **English** |
| `options[:sarvam_mode] = "codemix"` | `codemix` | English words in English, Indic in native script |
| `"verbatim"` / `"translit"` | ditto | filler-preserving / romanized |

- **Accepts WebM/OPUS natively** (also MP3/MP4/WAV/FLAC) — no transcode, no
  Dockerfile change.
- **REST caps at ~30s/file** → fits the incremental 3s-segment path (prod runs
  `SCRIBE_INCREMENTAL_ASR=true`). A >30s whole-file request errors → maps to a
  transient `BadResponse` → **Caller falls back** to the assignment's fallback
  model. Always pair Sarvam with a Whisper fallback.
- `Llm::Result` gained `:language`; a provider's detected language (Sarvam's
  `language_code`, "en" after translate) now flows to the persisted transcript.
- **Verified against the live Sarvam API** (real key): HTTP 200, multipart
  accepted, response parsed.

**Enable for a client** (per account or page — the seam is the ModelAssignment):
```ruby
sarvam = AiModel.find_by!(api_model_id: "saaras:v3")
whisper = AiModel.find_by!(api_model_id: "whisper-1")
ModelAssignment.find_or_create_by!(scope_type: "Account", scope_id: account.id, function: "asr") do |a|
  a.ai_model = sarvam
  a.fallback_ai_model = whisper           # long whole-file audio falls back here
end.update!(options: { "asr_mode" => "translate" })   # or sarvam_mode: "codemix"
```
The Sarvam provider (key backfilled from `SARVAM_API_KEY`), `saaras:v3` model,
and price are auto-provisioned on prod by migration `20260712030000`.

### 2. Realtime voice (OpenAI) — browser-direct via ephemeral token

`POST /api/v2/scribe_sessions/:id/realtime_token` mints a short-lived OpenAI
ephemeral client secret (`/v1/realtime/client_secrets`, ~10 min) the **browser**
uses to connect DIRECTLY to OpenAI realtime transcription — **the account key
never reaches the client**. Resolved via `ConfigResolver(function: :realtime)`,
default `gpt-4o-transcribe`. Gated behind `SCRIBE_REALTIME` (deployed **on**).

- **Verified against the live OpenAI API**: mints a real `ek_…` token.
- Realtime is a live-transcription **overlay** during recording; the
  authoritative transcript + structuring still come from the commit pipeline, so
  enabling it never changes committed results.

### 3. SDK 0.3.0 — `RealtimeTranscriber` (publish pending)

`record({ realtime: true })` streams the mic directly to OpenAI over WebRTC,
authorized by the backend ephemeral token, emitting partials on the existing
`onPartialTranscript` channel (replaces the segment+poll live path). Additive +
isolated: any realtime failure is swallowed; the durable recorder + commit are
untouched. Committed on the SDK repo; **you publish** `npm publish`.

## Sarvam "realtime"

Two tiers, by need:
- **Near-realtime (shipped):** the 3s-segment path with `saaras:v3` — each
  segment hits Sarvam REST (<30s cap) and partials surface every ~3s. Works
  today via the incremental path; no new transport.
- **True streaming (deferred):** Sarvam's WS (`wss://api.sarvam.ai/speech-to-text/ws`)
  authenticates with the **raw** account key (no ephemeral token) and needs
  **PCM 16kHz**, so it can't be browser-direct. It needs a backend WS proxy —
  deliberately NOT built blind (a persistent-socket proxy on Rails is a real
  infra addition that needs load testing). Documented as the next realtime step.

## To fully turn on realtime (order)

1. `npm publish` the SDK (0.3.0). *(Only you can.)*
2. Bump `care-medispeak-fe`'s SDK dep to `^0.3.0`, pass `record({ realtime: true })`
   (behind a config flag). Deploy the FE. *(Blocked on step 1 — the FE build
   installs the SDK from npm.)*
3. `SCRIBE_REALTIME` is already `true` on prod; the endpoint is live. The WebRTC
   browser connection is the one piece not exercisable without a live mic — test
   it end-to-end after step 2.

## Metering

- Sarvam ASR is metered per-minute like Whisper (`AudioModelPrice` Sarvam /
  saaras:v3, **$0.006/min ESTIMATE — confirm at sarvam.ai/pricing**).
- Realtime transcription is billed to our OpenAI account via the ephemeral
  session; it is not yet metered per-session (the browser streams directly, so
  the backend doesn't see the usage). Like live-form-fill, it's a known cost of
  an opt-in overlay — meter later if we expose realtime broadly.

## Security follow-ups (for you)

- **Rotate** the Sarvam key and the OpenAI/`msk_live`/DO tokens that passed
  through chat.
- The DO spec stores `OPENAI_ACCESS_TOKEN` as **plaintext** (`SARVAM_API_KEY`
  was added as `type: SECRET`). Convert the OpenAI (and AWS) values to SECRET.
