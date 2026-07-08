# Plan 001: Meter ASR calls at their real audio duration (stop billing every transcription at $0)

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan
> in `plans/README.md` — unless a reviewer dispatched you and told you they
> maintain the index.
>
> **Drift check (run first)**:
> `git diff --stat 84da325..HEAD -- app/services/scribe/orchestrator.rb app/services/scribe/asr_stage.rb`
> If either in-scope file changed since this plan was written, compare the
> "Current state" excerpts against the live code before proceeding; on a
> mismatch, treat it as a STOP condition.

## Status

- **Priority**: P1
- **Effort**: M
- **Risk**: LOW
- **Depends on**: none
- **Category**: bug
- **Planned at**: commit `84da325`, 2026-07-08

## Why this matters

Every ASR (speech-to-text) call in the scribe pipeline is metered with
`audio_seconds: 0`, hardcoded. ASR is billed **per minute** (`PriceBook`
multiplies `audio_seconds / 60 * price_per_minute`), so with zero seconds every
transcription costs `$0.00` in the ledger and every usage/analytics report shows
zero audio consumed. This is a direct revenue leak and makes audio usage
invisible. After this plan lands, each ASR `UsageEvent.audio_seconds` and its
`cost` reflect the real length of the uploaded audio, and the persisted
`Transcript.duration_seconds` is correct.

## Current state

Files involved and their roles:

- `app/services/scribe/orchestrator.rb` — composes the pipeline; downloads the
  audio blob and calls `AsrStage`. Contains the hardcoded `0`.
- `app/services/scribe/asr_stage.rb` — ASR wrapper; forwards `audio_seconds`
  into the provider call and copies it into `Result#duration_seconds`.
- `app/services/llm/adapters/openai_compatible.rb` — provider adapter; puts
  `audio_seconds` into `Llm::Usage` (do NOT modify — read-only reference).
- `app/services/metering/price_book.rb` — prices the call from `audio_seconds`
  (read-only reference).
- `app/services/metering/usage_recorder.rb` — persists `UsageEvent.audio_seconds`
  from `result.usage.audio_seconds` (read-only reference).

The hardcoded zero, `app/services/scribe/orchestrator.rb:63-74`:

```ruby
asr_result = with_audio do |audio_io|
  if audio_io.nil?
    raise Llm::Error, "no audio attached to scribe session"
  end

  Scribe::AsrStage.new(config: config).call(
    audio_io,
    language: session.language,
    mode: :transcribe,
    audio_seconds: 0
  )
end
```

The misleading "ffprobe optional" comment, `orchestrator.rb:282-299`:

```ruby
# Downloads the first attached audio blob into a Tempfile (ruby-openai's
# multipart layer needs an IO with #path, not a URL). blob.download works for
# Disk and S3/MinIO. Yields the rewound Tempfile and always closes it.
# Duration is best-effort: passed as audio_seconds: 0 (ffprobe optional).
def with_audio
  blob = session.audio_files.first
  return yield(nil) if blob.nil?

  tmp = Tempfile.new(["audio", ".bin"])
  tmp.binmode
  tmp.write(blob.download)
  tmp.rewind
  begin
    yield tmp
  ensure
    tmp.close!
  end
end
```

The duration flows straight through to the persisted transcript,
`orchestrator.rb:92-101` (so fixing `audio_seconds` also fixes
`Transcript.duration_seconds`):

```ruby
def persist_transcript!(asr_result)
  Transcript.create!(
    scribe_session: session,
    text: asr_result.text,
    language: asr_result.language,
    duration_seconds: asr_result.duration_seconds,
    ...
```

`AsrStage` copies `audio_seconds` into both the provider call and its Result,
`app/services/scribe/asr_stage.rb:19-33`:

```ruby
def call(audio_io, language: nil, mode: :transcribe, audio_seconds: 0)
  llm = Llm::Caller.transcribe(
    @config, audio_io,
    language: language, mode: mode, audio_seconds: audio_seconds
  )

  Result.new(
    text: llm.text,
    language: language,
    duration_seconds: audio_seconds,
    ...
```

The adapter's docstring already **claims the caller supplies duration**,
`asr_stage.rb:1-5`:

```ruby
# The ASR function: audio -> a normalized transcript. Provider-agnostic; wraps
# Llm::Caller.transcribe (which owns provider fallback). Duration is supplied
# by the caller (measured via ffprobe/blob metadata) because most providers do
# not return it and ASR is billed per minute.
```

The pricing math that zero defeats, `app/services/metering/price_book.rb:56-59`:

```ruby
def audio_cost(usage, price)
  seconds = usage&.audio_seconds.to_f
  (seconds / 60.0) * price.price_per_minute.to_f
end
```

**Environment fact (verified during recon):** CI installs `libvips` and
`google-chrome-stable`, NOT `ffmpeg`/`ffprobe` — see `.github/workflows/ci.yml:77`:
`sudo apt-get install ... google-chrome-stable curl libjemalloc2 libvips postgresql-client`.
Rails' built-in `ActiveStorage::Analyzer::AudioAnalyzer` shells out to `ffprobe`;
with ffprobe absent, `blob.metadata["duration"]` will **not** be populated. You
must verify what is available before choosing the measurement mechanism (Step 1).

**Convention:** `Llm::Usage` (`app/services/llm/usage.rb`) carries an
`estimated` boolean; `UsageRecorder` persists it to `UsageEvent.estimated`. If
you fall back to an approximate duration, set `estimated: true` so the row is
flagged. Money is `BigDecimal`; audio cost is a Float computed by `PriceBook`.

## Commands you will need

| Purpose | Command | Expected on success |
|---|---|---|
| Prepare test DB | `ASDF_RUBY_VERSION=3.2.2 bin/rails db:test:prepare` | exit 0 |
| Single test file | `ASDF_RUBY_VERSION=3.2.2 bin/rails test test/services/scribe/orchestrator_test.rb` | 0 failures, 0 errors |
| Tests (all) | `ASDF_RUBY_VERSION=3.2.2 bin/rails test` | 0 failures |
| Lint | `ASDF_RUBY_VERSION=3.2.2 bin/rubocop` | no offenses |
| Probe check | `which ffprobe ffmpeg` | (records what exists) |

(The `ASDF_RUBY_VERSION=3.2.2` prefix is required on this machine so asdf
resolves Ruby 3.2.2; without it `bin/rails` may not run.)

## Scope

**In scope** (the only files you should modify or create):
- `app/services/scribe/orchestrator.rb` (modify)
- `app/services/scribe/audio_duration.rb` (create — the helper)
- `test/services/scribe/orchestrator_test.rb` (extend)
- `test/services/scribe/audio_duration_test.rb` (create — only if Step 1 yields a real probe; otherwise skip and note why)

**Out of scope** (do NOT touch, even though they look related):
- `app/services/scribe/asr_stage.rb` — already forwards `audio_seconds`
  correctly; it only needs a non-zero value passed in. Do not change its signature.
- `app/services/llm/adapters/openai_compatible.rb`, `app/services/metering/price_book.rb`,
  `app/services/metering/usage_recorder.rb` — they already consume
  `audio_seconds` correctly. The bug is only that the orchestrator passes `0`.
- `.github/workflows/ci.yml`, `Dockerfile`, `Gemfile` — do NOT add ffmpeg or an
  audio gem. Installing new system/gem dependencies is a maintainer decision;
  if the measurement requires it, that is a STOP condition (see below).

## Git workflow

- Branch: `advisor/001-meter-asr-audio-duration`
- Commit per logical unit; message style matches the repo log (short imperative,
  e.g. `git log` shows "Add …", "Fix …"). Suggested: `Meter ASR at real audio duration`.
- Do NOT push or open a PR unless the operator instructed it.

## Steps

### Step 1: Determine the available duration source (investigation — no code yet)

Run the probe check and inspect the ActiveStorage analyzer registration:

```
which ffprobe ffmpeg
ASDF_RUBY_VERSION=3.2.2 bin/rails runner 'puts ActiveStorage.analyzers.inspect'
```

Decide the measurement mechanism from the result:

- **If `ffprobe` exists**: prefer measuring via the ActiveStorage blob analyzer
  (`blob.analyze; blob.metadata["duration"]`) or by shelling `ffprobe` against
  the downloaded tempfile. This yields an exact duration; `estimated: false`.
- **If `ffprobe` is absent** (expected in CI per `ci.yml:77`): there is no exact
  probe. Choose the byte-size **estimate** fallback described in Step 2, and set
  `estimated: true`. Only proceed with the estimate if it is acceptable to the
  maintainer — if not, this is a STOP condition.

Record which branch you took in the PR description. Do not add ffmpeg to the
environment yourself (out of scope).

**Verify**: you have written down (a) whether ffprobe exists and (b) which
measurement branch you will implement. No verification command — this is a
decision gate.

### Step 2: Create the `Scribe::AudioDuration` helper

Create `app/services/scribe/audio_duration.rb`. It takes the ActiveStorage blob
(and, when helpful, the already-downloaded tempfile from `with_audio`) and
returns a duration in **seconds** plus whether it is an estimate. Target shape:

```ruby
module Scribe
  # Best-effort audio duration for per-minute ASR billing. Returns a Result with
  # `seconds` (Float) and `estimated` (Boolean). Never raises — a measurement
  # failure degrades to an estimate rather than aborting the pipeline. See
  # plan 001 for why: ASR is billed per minute and must not be metered at 0.
  class AudioDuration
    Result = Struct.new(:seconds, :estimated, keyword_init: true)

    # Rough bytes-per-second used only when no exact probe is available. Chosen
    # for a common compressed-audio bitrate; flagged estimated: true so the
    # UsageEvent is marked approximate. Adjust with maintainer guidance.
    ESTIMATE_BYTES_PER_SECOND = 16_000.0

    def self.for_blob(blob, file: nil)
      new(blob, file: file).call
    end

    def initialize(blob, file: nil)
      @blob = blob
      @file = file
    end

    def call
      exact = exact_seconds
      return Result.new(seconds: exact, estimated: false) if exact&.positive?

      Result.new(seconds: estimate_seconds, estimated: true)
    rescue StandardError
      Result.new(seconds: estimate_seconds, estimated: true)
    end

    private

    # Returns an exact duration in seconds when a probe is available, else nil.
    # If ffprobe is present, ActiveStorage's audio analyzer populates
    # blob.metadata["duration"]; otherwise this returns nil and we estimate.
    def exact_seconds
      @blob.analyze unless @blob.analyzed?
      @blob.metadata["duration"]&.to_f
    end

    def estimate_seconds
      (@blob.byte_size.to_f / ESTIMATE_BYTES_PER_SECOND).round(3)
    end
  end
end
```

If Step 1 found `ffprobe` present, keep `exact_seconds`. If it is absent, the
`exact_seconds` path simply returns nil and the estimate is used — the code
above handles both without branching on the environment. Do not hardcode the
environment result into the helper.

**Verify**: `ASDF_RUBY_VERSION=3.2.2 bin/rails runner 'puts Scribe::AudioDuration'`
→ prints `Scribe::AudioDuration` (class loads with no syntax/name error).

### Step 3: Thread the measured duration into the ASR call

In `app/services/scribe/orchestrator.rb`, change `with_audio` to also yield the
blob (or measure inside it) so `ensure_transcript!` can pass a real
`audio_seconds`. Minimal change: in `ensure_transcript!` compute the duration
from the session's blob and pass it instead of `0`.

Replace the `audio_seconds: 0` at `orchestrator.rb:63-74` with the measured value.
Suggested shape inside `ensure_transcript!`:

```ruby
asr_result = with_audio do |audio_io|
  raise Llm::Error, "no audio attached to scribe session" if audio_io.nil?

  duration = Scribe::AudioDuration.for_blob(session.audio_files.first, file: audio_io)

  Scribe::AsrStage.new(config: config).call(
    audio_io,
    language: session.language,
    mode: :transcribe,
    audio_seconds: duration.seconds
  )
end
```

Note: `AsrStage` copies `audio_seconds` into `Result#duration_seconds`, and the
adapter wraps it into `Llm::Usage.new(audio_seconds:)`. It does NOT set
`estimated` from the duration helper, so if you want the `estimated` flag to
reach the `UsageEvent`, that is an OPTIONAL follow-up (`Llm::Usage` supports
`estimated:` but the ASR adapter builds `Usage.new(audio_seconds:)` without it).
Do not expand scope to plumb the flag unless the maintainer asks — record it as
a deferred follow-up instead. The load-bearing fix is the non-zero seconds.

Also update the stale comment at `orchestrator.rb:285` ("audio_seconds: 0
(ffprobe optional)") to describe the real behavior.

**Verify**: `ASDF_RUBY_VERSION=3.2.2 bin/rails test test/services/scribe/orchestrator_test.rb`
→ existing tests still pass (0 failures). The pre-existing tests attach a 1-byte
`StringIO`, so they will now compute a tiny non-zero (or estimated) duration —
they only assert `UsageEvent.count`/`function`, so they must remain green.

### Step 4: Add the billing assertions to the orchestrator test

See the Test plan below, then run the full file.

**Verify**: `ASDF_RUBY_VERSION=3.2.2 bin/rails test test/services/scribe/orchestrator_test.rb`
→ 0 failures, including the new assertions.

## Test plan

Extend `test/services/scribe/orchestrator_test.rb` (model the new test after the
existing `"runs ASR once, fills transcript + form outputs, records usage"` test
at lines 47–90; it already stubs ASR via `stub_asr` and asserts on `UsageEvent`).

Add one test: **"ASR usage_event is metered at the real audio duration and a
non-zero cost"**. To keep it deterministic and independent of whether ffprobe
exists in the runner, stub the duration helper to a fixed value:

- `Scribe::AudioDuration.stubs(:for_blob).returns(Scribe::AudioDuration::Result.new(seconds: 90.0, estimated: false))`
  (the test file already `require "mocha/minitest"`, so `.stubs` is available).
- Create a matching audio price so `PriceBook` returns a non-zero cost. The
  default ASR config resolves to `provider_kind: :openai_compatible`, model
  `whisper-1` (verified: `Llm::DefaultConfigProvider` +
  `openai_compatible.rb:27` records `provider: config.provider_kind.to_s`). So
  the recorded `UsageEvent` has `provider = "openai_compatible"`, `model =
  "whisper-1"`. The `:audio_model_price` factory defaults `provider "openai"`
  which will NOT match — create it explicitly:
  `create(:audio_model_price, provider: "openai_compatible", model: "whisper-1", price_per_minute: 0.006)`.
- Run `Scribe::Orchestrator.new(session).call`.
- Assert on the ASR event:
  `asr = UsageEvent.find_by(scribe_session_id: session.id, function: "asr")`
  - `assert_equal 90.0, asr.audio_seconds.to_f`
  - `assert_equal (90.0 / 60.0 * 0.006).round(6), asr.cost.to_f` (i.e. `0.009`)
- Assert the transcript persisted the same duration:
  `assert_equal 90.0, session.reload.transcript.duration_seconds.to_f`.

Optionally, only if Step 1 found a real `ffprobe`: add
`test/services/scribe/audio_duration_test.rb` with a real short audio fixture of
known length asserting `Scribe::AudioDuration.for_blob(blob).seconds` is within
tolerance. If ffprobe is absent, SKIP this file and note in the PR that the
helper's exact path is untestable in this environment.

Verification: `ASDF_RUBY_VERSION=3.2.2 bin/rails test test/services/scribe/orchestrator_test.rb`
→ all pass, including the new test.

## Done criteria

Machine-checkable. ALL must hold:

- [ ] `ASDF_RUBY_VERSION=3.2.2 bin/rails test test/services/scribe/orchestrator_test.rb` → 0 failures, 0 errors, includes the new metering assertion
- [ ] `ASDF_RUBY_VERSION=3.2.2 bin/rails test` → 0 failures
- [ ] `ASDF_RUBY_VERSION=3.2.2 bin/rubocop` → no offenses
- [ ] `grep -n "audio_seconds: 0" app/services/scribe/orchestrator.rb` → no matches
- [ ] No files outside the in-scope list are modified (`git status`)
- [ ] `plans/README.md` status row updated

## STOP conditions

Stop and report back (do not improvise) if:

- The "Current state" excerpts don't match the live code (the file drifted since
  commit `84da325`).
- Step 1 finds **no** exact probe (`ffprobe` absent) AND the byte-size estimate
  is not acceptable — do NOT add ffmpeg to CI/Dockerfile or a new gem yourself
  (out of scope). Report the options (add ffmpeg system dep, add a pure-Ruby
  audio gem, or accept the flagged estimate) and let the maintainer choose.
- Any verification fails twice after a reasonable fix attempt.
- The fix appears to require modifying `asr_stage.rb`'s public signature or any
  adapter/metering file (it should not — the seconds value is the only change).

## Maintenance notes

For whoever owns this after it lands:

- If ffmpeg/ffprobe is later added to CI and prod, the helper's exact path will
  start returning real durations and the estimate branch becomes a rare
  fallback — revisit `ESTIMATE_BYTES_PER_SECOND` and consider dropping the
  estimate entirely.
- The `estimated` flag is NOT currently plumbed from `AudioDuration` to the ASR
  `Llm::Usage`/`UsageEvent.estimated` (deferred — see Step 3). If billing needs
  to distinguish estimated audio, wire it through the ASR adapter's
  `Llm::Usage.new(audio_seconds:, estimated:)` call.
- Reviewer should scrutinize: the provider/model used in the cost test matches
  what the default config actually records (`openai_compatible` / `whisper-1`),
  and that the estimate constant is documented as approximate.
- Plan 002 relies on a real duration to compute a credit hold estimate; once
  this lands, that estimate can use `Scribe::AudioDuration` too.
