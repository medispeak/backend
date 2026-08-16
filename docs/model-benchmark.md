# Model benchmark (`bench:*`)

A local harness for comparing ASR and structuring models side by side on
synthetic clinical fixtures: **accuracy, latency and cost per model**, through
the exact production stages (`Scribe::AsrStage`, `Scribe::StructuringStage`).
Nothing here touches sessions, metering or the ledger.

## Quick start

```bash
bin/rails bench:models                    # what can be benched + which providers have keys
bin/rails bench:asr                       # all active can_transcribe models over 5 clips
bin/rails bench:structuring               # all active can_structure models over 5 cases
bin/rails bench:all
```

Filters and knobs (all optional):

| Env | Meaning |
|---|---|
| `MODELS=whisper,saaras,18` | Only models whose `api_model_id` / display name contains a term (or numeric id). Default: all active models with the capability. |
| `FIXTURES=en_fever_followup,hi_bp_checkup` | Subset of fixture ids. |
| `RUNS=3` | Repeat each call (latency stability). |
| `MODE=translate` | ASR mode (default `transcribe`). |
| `LABEL="after prompt tweak"` | Free text stored in the report. |
| `OPENROUTER_API_KEY`, `OPENAI_ACCESS_TOKEN`, `ANTHROPIC_API_KEY`, `SARVAM_API_KEY` | Override the provider row's key for the run (handy when the local row still holds the seed placeholder). Providers with no usable key are skipped with a note. |

Each run prints a table and writes `bench/results/<timestamp>-<function>.md`
(per-model summary, per-fixture matrix, failures, and for ASR every transcript)
plus a `.json` with every row for your own analysis.

## What is measured

**ASR** — per model × clip: **WER** against the fixture's script (word-level
Levenshtein after normalizing rendering-only differences: case, punctuation,
Unicode form, Malayalam legacy-vs-atomic chillus, `500mg`/`500 mg`,
`150/95`/`150-95`), wall-clock latency, audio seconds, and price-book cost
(`$/audio-minute` in the summary).

**Script convention (read before comparing Indic clips):** references keep
English loanwords, drug names and units in Latin script and use Western
digits — exactly what was fed to the TTS and how a bilingual clinician types.
Most engines transliterate those into the native script (Sarvam writes
"back pain" as ബാക്ക് പെയിൻ), which counts as errors here *by design*: on
`mix_manglish_backpain` that alone is a ~0.2 floor. Use the per-fixture matrix
and the transcripts section to separate transliteration from real misses.

**Structuring** — per model × case: **field accuracy** against `expected`
(exact after normalization by default; per-key `scoring` rules: `contains:x`,
`any_of:a|b`, `number_tolerance:n`; multi-selects compare as sets; an expected
`null` is right only if the model also returned null/blank), latency, tokens,
price-book cost (`$/call`), plus schema-validity warnings from the real
validator/repair loop.

Ranking: fewest failures first, then score (ASR ascending WER, structuring
descending accuracy) over successful calls, then p50 latency — so a model that
400s on the hard clips can't out-rank one that transcribes them all. `warn`
counts structuring calls whose output was still schema-invalid after the one
repair re-ask (marked `*` in the per-fixture matrix); their tokens/cost include
the repair call.

## Fixtures

- `bench/fixtures/asr/<id>.json` — `{ id, title, language, code_mix, turns: [{speaker, text}] }`.
  The reference transcript is the turns joined. Audio lives at `bench/audio/<id>.mp3`
  and is **committed** so WER stays comparable between runs.
- `bench/fixtures/structuring/<id>.json` — `{ id, title, language, system_prompt, transcript,
  fields: [InlineField payloads: key/label/type/enum/minimum/maximum/description],
  expected: {key: value}, scoring: {key: rule} }`.

Add a case by dropping a JSON file in; add a clip by adding the fixture and
running `FIXTURES=<id> bin/rails bench:audio`.

## Regenerating audio

`bin/rails bench:audio` synthesizes each ASR fixture: one TTS call per turn with
distinct doctor/patient voices, a short pause between turns, concatenated with
`ffmpeg` (required) into mono 24 kHz MP3. English uses OpenAI TTS
(`gpt-4o-mini-tts`); Hindi/Malayalam/Manglish use Sarvam Bulbul v2, which speaks
Indic scripts natively. Force one with `TTS=openai|sarvam`. Regenerating changes
the audio, so previous WER numbers stop being comparable — do it deliberately.

## Caveats

- Synthetic TTS audio is cleaner than clinic audio; treat absolute WER as
  optimistic and use it for *relative* comparison.
- Clips are mono 24 kHz MP3; production sends browser WebM/Opus segments.
  Container/codec handling is therefore outside what this harness measures.
- `ffprobe`/`ffmpeg` are required (clip duration drives per-minute cost); the
  bench aborts loudly if they are missing rather than reporting $0.
- Latency includes network from wherever you run it.
- OpenRouter STT models are transcribe-only (`MODE=translate` will fail them),
  and their upstream timeout is ~60 s per request.
