# Plan 020: Assemble chunked audio once, in the processing job, and transcribe it without a second full-file download

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, ADD a new row for plan 020 to
> `plans/README.md` (the table currently ends at 019); exact values:
> `| 020 | Assemble chunked audio once, transcribe without a second download | P2 | M | — | TODO |`.
> If a reviewer maintains the index, skip this.
>
> **Drift check (run first)**:
> `git diff --stat 58fd6a5..HEAD -- app/controllers/api/v2/scribe_sessions_controller.rb app/services/scribe/chunk_assembler.rb app/services/scribe/orchestrator.rb app/jobs/process_scribe_session_job.rb app/services/scribe/audio_duration.rb test/integration/api/v2/audio_chunks_test.rb`
> If any in-scope file changed since this plan was written, compare the
> "Current state" excerpts against the live code before proceeding; on a
> mismatch, treat it as a STOP condition.

## Status

- **Priority**: P2
- **Effort**: M
- **Risk**: MED
- **Depends on**: none
- **Category**: perf
- **Planned at**: commit `58fd6a5`, 2026-07-11

## Why this matters

On the chunked-upload path the audio content is pulled out of object storage
**twice**. `commit` calls `Scribe::ChunkAssembler.assemble!`, which downloads
every chunk (one storage GET per chunk) and PUTs a stitched blob onto
`session.audio_files`; then `ProcessScribeSessionJob` → `Orchestrator#with_audio`
runs `blob.download` — a **second** full-file GET of the exact same audio — just
to feed ASR. That doubles egress and adds latency on the hot path to the
transcript, on a request the clinician is waiting on. This plan makes it so the
audio is no longer re-downloaded to feed ASR — the assembled tempfile is fed to
ASR directly, removing the second full-file GET on the ASR path. Assembly moves
out of `commit` and into the job, where the single reassembled tempfile is both
attached for durable storage/playback **and** reused directly for ASR.

Note: ActiveStorage's `AnalyzeJob` and `AudioDuration#exact_seconds` may still
read the blob for metadata (e.g. content analysis / duration probing); removing
those reads is out of scope. This plan only removes the second full-file GET on
the ASR feed path.

## Current state

The relevant files, each with one line on its role:

- `app/controllers/api/v2/scribe_sessions_controller.rb` — the v2 scribe API;
  `commit` (≈158–221) assembles chunks and holds credit, `commit_estimate`
  (≈271–276) sizes the hold, `base_audio_type` (≈331–333) normalizes MIME types.
- `app/services/scribe/chunk_assembler.rb` — stitches chunks into one attached blob.
- `app/services/scribe/orchestrator.rb` — the pipeline; `ensure_transcript!`
  (63–93) runs ASR once, `with_audio` (321–334) downloads the blob to a tempfile,
  `audio_extension` (340–351) picks the file extension.
- `app/jobs/process_scribe_session_job.rb` — runs the Orchestrator asynchronously.
- `app/services/scribe/audio_duration.rb` — best-effort duration; has a byte-size
  estimator used when no exact probe is available.
- `test/integration/api/v2/audio_chunks_test.rb` — end-to-end chunked-upload tests.

Excerpts as they exist today:

- **`commit` assembles at commit time** — `scribe_sessions_controller.rb:179-195`:
  ```ruby
  # Browser clients upload via chunked parts; stitch them into the session's
  # canonical audio blob so the Orchestrator path below runs unchanged. This
  # sits BEFORE the quota hold (plan 002) and OUTSIDE with_idempotency so a
  # no-audio commit is a plain, retryable 422 and never a cached response.
  # The audio_files.blank? guard makes it a no-op once a blob exists (a
  # single-shot upload or a prior reassembly), so a retried commit is safe.
  if session.audio_files.blank? && session.audio_chunks.exists?
    Scribe::ChunkAssembler.assemble!(session)
  end
  if session.audio_files.blank?
    render_error(
      code: "audio_upload_failed",
      message: "No audio uploaded for this session",
      status: :unprocessable_entity
    )
    return
  end
  ```

- **The commit hold estimate reads the blob's duration** —
  `scribe_sessions_controller.rb:271-276`:
  ```ruby
  def commit_estimate(session)
    blob = session.audio_files.first
    seconds = blob ? Scribe::AudioDuration.for_blob(blob).seconds.to_f : 0.0
    minutes = [ seconds / 60.0, COMMIT_ESTIMATE_MIN_MINUTES ].max
    (minutes * COMMIT_ESTIMATE_RATE_PER_MINUTE).round(6)
  end
  ```
  `COMMIT_ESTIMATE_MIN_MINUTES = 1.0` (`:263`) is the floor when the estimate
  rounds to ~0; `COMMIT_ESTIMATE_RATE_PER_MINUTE = 0.02` (`:260`).

- **`ChunkAssembler` downloads every chunk and attaches a blob** —
  `app/services/scribe/chunk_assembler.rb:11-23`:
  ```ruby
  def assemble!(session)
    chunks = session.audio_chunks.order(:seq).to_a
    return false if chunks.empty?

    content_type = chunks.first.content_type.presence || "audio/webm"
    tmp = Tempfile.new([ "scribe_audio", ".bin" ])
    tmp.binmode
    chunks.each { |c| tmp.write(c.data.download) }
    tmp.rewind
    session.audio_files.attach(io: tmp, filename: "consultation", content_type: content_type)
    tmp.close!
    true
  end
  ```
  Note the ordered write `chunks.each { |c| tmp.write(c.data.download) }` over
  `order(:seq)` — this is the byte-for-byte concatenation the tests assert on.

- **`Orchestrator#with_audio` re-downloads the blob for ASR** —
  `app/services/scribe/orchestrator.rb:321-334`:
  ```ruby
  def with_audio
    blob = session.audio_files.first
    return yield(nil) if blob.nil?

    tmp = Tempfile.new(["audio", audio_extension(blob)])
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
  It is called by `ensure_transcript!` (`orchestrator.rb:68-81`), which passes
  the yielded IO to `Scribe::AsrStage` and measures duration with
  `Scribe::AudioDuration.for_blob(session.audio_files.first, file: audio_io)`.

- **`audio_extension` maps filename/content-type to a real audio extension** —
  `orchestrator.rb:340-351` (Whisper infers format from the extension, so
  `.bin` is not acceptable for the ASR tempfile):
  ```ruby
  CONTENT_TYPE_EXT = {
    "audio/mpeg" => ".mp3", "audio/mp3" => ".mp3", "audio/mp4" => ".mp4",
    "audio/wav" => ".wav", "audio/x-wav" => ".wav", "audio/webm" => ".webm",
    "audio/ogg" => ".ogg", "audio/m4a" => ".m4a", "audio/aac" => ".aac"
  }.freeze

  def audio_extension(blob)
    from_name = File.extname(blob.filename.to_s).downcase
    return from_name if from_name.present?

    CONTENT_TYPE_EXT[blob.content_type] || ".mp3"
  end
  ```

- **`AudioDuration` has a byte-size estimator** — `app/services/scribe/audio_duration.rb:12,42-44`:
  ```ruby
  ESTIMATE_BYTES_PER_SECOND = 16_000.0
  # ...
  def estimate_seconds
    (@blob.byte_size.to_f / ESTIMATE_BYTES_PER_SECOND).round(3)
  end
  ```
  This is a private instance method that reads `@blob.byte_size`; it is not a
  class-level helper you can call on raw bytes. See Step 2 for how to reuse the
  same constant/heuristic against summed chunk sizes.

- **Chunk byte-sizes are read via the attached blob** — the controller already
  sums chunk sizes this way (`scribe_sessions_controller.rb:121-122`):
  ```ruby
  other_bytes = session.audio_chunks.where.not(seq: seq)
                       .with_attached_data.sum { |c| c.data.blob&.byte_size.to_i }
  ```
  `ScribeAudioChunk` (`app/models/scribe_audio_chunk.rb`) is
  `belongs_to :scribe_session; has_one_attached :data` with a `seq` uniqueness
  scope — so `chunk.data.blob.byte_size` and `chunk.data.download` are the
  per-chunk accessors.

- **The job runs the Orchestrator** — `app/jobs/process_scribe_session_job.rb:18-33`;
  in test the ActiveJob adapter is `:inline`, so `commit` → `perform_later` →
  `perform` → `Orchestrator#call` all run synchronously within the request.

Repo conventions that apply here:

- Services live in `app/services/scribe/` as small modules/classes. `ChunkAssembler`
  is a `module_function` module; `AudioDuration` and `Orchestrator` are classes.
  A new `Scribe::AudioSource` should match one of these shapes.
- ASR must see a tempfile whose **extension** is a real audio extension (see
  `audio_extension` above) — do not hand ASR a `.bin` tempfile.
- The reassembled bytes MUST equal the ordered `order(:seq)` concatenation of
  chunk bytes — there are two tests asserting exactly this (see Test plan).

## Commands you will need

| Purpose            | Command                                                                                     | Expected on success |
|--------------------|---------------------------------------------------------------------------------------------|---------------------|
| Chunked-path tests | `ASDF_RUBY_VERSION=3.4.1 bin/rails test test/integration/api/v2/audio_chunks_test.rb`        | all pass, 0 failures |
| Full test suite    | `ASDF_RUBY_VERSION=3.4.1 bin/rails test`                                                     | 0 failures, 0 errors |
| Lint               | `ASDF_RUBY_VERSION=3.4.1 bin/rubocop`                                                        | no offenses         |

(Ruby is pinned to 3.4.1 by `.tool-versions`; every Ruby command must be
prefixed with `ASDF_RUBY_VERSION=3.4.1`. The test env uses the `:inline`
ActiveJob adapter, so `commit` → job → assemble → ASR run synchronously inside
the request under test.)

## Scope

**In scope** (the only files you should modify):
- `app/controllers/api/v2/scribe_sessions_controller.rb` — `commit` guard and `commit_estimate`.
- `app/services/scribe/audio_source.rb` — **create**; the single seam that yields a full-audio tempfile.
- `app/services/scribe/orchestrator.rb` — `with_audio` delegates to `Scribe::AudioSource`.
- `app/services/scribe/chunk_assembler.rb` — **retained**; its seq-ordered concatenation is reused by (called from) `AudioSource`. Do NOT delete it. Its unit test `test/services/scribe/chunk_assembler_test.rb` must remain untouched. See Step 3.
- `app/jobs/process_scribe_session_job.rb` — only if a change is genuinely required (it should not be).
- `test/integration/api/v2/audio_chunks_test.rb` — add one case (Test plan).

**Out of scope** (do NOT touch, even though they look related):
- The metering/quota math beyond the estimate **source** — `Metering::QuotaGuard`,
  `Metering::UsageRecorder`, `COMMIT_ESTIMATE_RATE_PER_MINUTE`. Only where the
  estimate's byte count comes from may change.
- The ASR/structuring model seam — `Llm::ConfigResolver`, `Scribe::AsrStage`,
  `Scribe::StructuringStage`. Do NOT change **how** ASR is called, only **where
  its bytes come from**.
- The single-shot `audio` action and its content-type normalization
  (`scribe_sessions_controller.rb#audio`, `base_audio_type`).
- `app/models/scribe_session.rb`, `app/models/scribe_audio_chunk.rb` — the
  attachments/validations are correct as-is.

## Git workflow

- Branch off the current branch: `advisor/020-collapse-commit-to-asr-roundtrip`.
- Commit per logical unit (per step is fine). Match the repo's imperative,
  capitalized commit style (recent history: `Add native chunked and resumable
  audio upload`, `Scope CORS to /api/* for browser scribe clients`).
- Do NOT push or open a PR unless the operator instructed it.

## Steps

Order the work so the pipeline is never broken between steps: introduce the new
`AudioSource` seam and route the Orchestrator through it (Steps 1–3) **before**
removing commit-time assembly (Step 4), so the assemble-from-chunks path already
exists in the job when `commit` stops doing it.

### Step 1: Create `Scribe::AudioSource` — one tempfile of the full audio

Create `app/services/scribe/audio_source.rb`. It yields a **rewound local
Tempfile** of the full session audio and always closes it, downloading the
content exactly once. Prefer an already-attached blob; otherwise assemble from
chunks into one tempfile and attach that same tempfile for durable
storage/playback (choice A: one playable file), then reuse it for ASR.

Target shape:
```ruby
require "tempfile"

module Scribe
  # Yields a rewound local Tempfile of the FULL session audio and always closes
  # it. Downloads the audio content EXACTLY ONCE:
  #   - if session.audio_files is attached (single-shot upload, or a prior
  #     reassembly): download that blob once.
  #   - else if chunks exist: stream each chunk (in seq order) into ONE tempfile
  #     — the only read of the content — then attach that SAME tempfile to
  #     session.audio_files for durable storage/playback and reuse it for ASR.
  # Never downloads the assembled blob back for ASR.
  module AudioSource
    module_function

    # Yields a Tempfile (or nil when the session has neither a blob nor chunks).
    def with_audio(session)
      blob = session.audio_files.first
      if blob
        yield_blob(blob) { |io| return yield(io) }
      elsif session.audio_chunks.exists?
        yield_assembled(session) { |io| return yield(io) }
      else
        yield(nil)
      end
    end

    def yield_blob(blob)
      tmp = Tempfile.new([ "audio", extension_for(blob.filename.to_s, blob.content_type) ])
      tmp.binmode
      tmp.write(blob.download)
      tmp.rewind
      begin
        yield tmp
      ensure
        tmp.close!
      end
    end

    def yield_assembled(session)
      chunks = session.audio_chunks.order(:seq).to_a
      content_type = chunks.first.content_type.presence || "audio/webm"
      tmp = Tempfile.new([ "scribe_audio", extension_for(nil, content_type) ])
      tmp.binmode
      chunks.each { |c| tmp.write(c.data.download) } # the ONLY read of the content
      tmp.rewind
      # Attach the SAME bytes for durable storage/playback (choice A). Attaching
      # from the tempfile — not re-downloading a blob — keeps the content read once.
      session.audio_files.attach(io: tmp, filename: "consultation", content_type: content_type)
      tmp.rewind
      begin
        yield tmp
      ensure
        tmp.close!
      end
    end

    # Whisper infers format from the file extension, so the tempfile must carry a
    # real audio extension — never ".bin". Prefer the filename extension; fall
    # back to the content-type. Mirrors Orchestrator#audio_extension.
    CONTENT_TYPE_EXT = {
      "audio/mpeg" => ".mp3", "audio/mp3" => ".mp3", "audio/mp4" => ".mp4",
      "audio/wav" => ".wav", "audio/x-wav" => ".wav", "audio/webm" => ".webm",
      "audio/ogg" => ".ogg", "audio/m4a" => ".m4a", "audio/aac" => ".aac"
    }.freeze

    def extension_for(filename, content_type)
      from_name = File.extname(filename.to_s).downcase
      return from_name if from_name.present?

      CONTENT_TYPE_EXT[content_type] || ".mp3"
    end
  end
end
```
Notes:
- `attach(io: tmp)` reads `tmp` to end-of-file, so the `tmp.rewind` **after**
  the attach (before `yield`) is required — without it ASR receives an
  empty/partial stream. Keep both rewinds.
- The assembled write loop MUST stay `session.audio_chunks.order(:seq).to_a`
  then `chunks.each { |c| tmp.write(c.data.download) }` — byte-identical to
  `ChunkAssembler` so the concatenation invariant holds.

**Verify**: `ASDF_RUBY_VERSION=3.4.1 bin/rubocop app/services/scribe/audio_source.rb`
→ no offenses (file parses and lints).

### Step 2: Route the Orchestrator through `AudioSource` (no ASR-call change)

In `app/services/scribe/orchestrator.rb`, replace the body of `with_audio`
(321–334) so it delegates to `Scribe::AudioSource.with_audio(session)`, and
delete the now-unused private `audio_extension` + `CONTENT_TYPE_EXT`
(340–351, moved into `AudioSource`). Do NOT touch `ensure_transcript!`'s ASR
call — it still does `with_audio { |audio_io| ... AsrStage ... }`; only the
source of `audio_io` moves.

Target shape:
```ruby
def with_audio(&block)
  Scribe::AudioSource.with_audio(session, &block)
end
```
`ensure_transcript!` (63–93) is unchanged; it still guards `audio_io.nil?` and
still measures `Scribe::AudioDuration.for_blob(session.audio_files.first, file: audio_io)`.
On the chunked path `AudioSource` attaches the blob **before** yielding, so
`session.audio_files.first` is present by the time duration is measured.

**Verify**: `ASDF_RUBY_VERSION=3.4.1 bin/rails test test/integration/api/v2/audio_chunks_test.rb`
→ all existing tests pass (the two concatenation/single-shot-equality tests and
the no-audio 422 still hold because the job runs inline and attaches the blob).

### Step 3: Move `ChunkAssembler` from the commit path to the processing path

`Scribe::ChunkAssembler` is **retained** — the file
`app/services/scribe/chunk_assembler.rb` and its unit test
`test/services/scribe/chunk_assembler_test.rb` both stay and must remain
untouched. What changes is **who calls it**: after Step 4, the `commit` action no
longer calls `Scribe::ChunkAssembler.assemble!`; the processing path does.

`AudioSource.yield_assembled` reuses `ChunkAssembler`'s exact seq-ordered
concatenation to build the full-audio tempfile — either by calling
`Scribe::ChunkAssembler.assemble!(session)` (which attaches the stitched blob)
or by inlining its byte-identical `order(:seq)` + `chunks.each { |c|
tmp.write(c.data.download) }` loop. Whichever it does, the assembled tempfile is
fed to ASR directly and attached to `session.audio_files`; the assembler is now
driven from the job, not from `commit`.

**Verify**: `grep -rn "ChunkAssembler" app/controllers/api/v2/scribe_sessions_controller.rb`
→ **no matches** in the controller (the `commit` action no longer assembles).
`ChunkAssembler` and its test remain present — do NOT expect
`grep -rn "ChunkAssembler" app/ test/` to be empty.

### Step 4: Stop assembling at commit; defer assembly to the job

In `app/controllers/api/v2/scribe_sessions_controller.rb#commit`, remove the
commit-time assembly and replace the no-audio guard so it 422s only when there
is NEITHER a single-shot blob NOR any chunk. Replace lines `179-195` (the
`if session.audio_files.blank? && session.audio_chunks.exists?` block plus the
`if session.audio_files.blank?` guard) with:
```ruby
# A committable session must have SOME audio: either a single-shot blob or at
# least one uploaded chunk. Chunk reassembly is deferred to the processing job
# (Scribe::AudioSource) so the audio content is read exactly once on the way to
# ASR — the job assembles and transcribes from a single tempfile rather than
# assembling here and re-downloading the blob for ASR. This guard sits BEFORE the
# quota hold and OUTSIDE with_idempotency so a no-audio commit is a plain,
# retryable 422 and never a cached response.
if session.audio_files.blank? && !session.audio_chunks.exists?
  render_error(
    code: "audio_upload_failed",
    message: "No audio uploaded for this session",
    status: :unprocessable_entity
  )
  return
end
```
A committable session with only chunks now proceeds; the job attaches
`audio_files` during processing (an observable change — see Maintenance notes).

**Verify**: `ASDF_RUBY_VERSION=3.4.1 bin/rails test test/integration/api/v2/audio_chunks_test.rb`
→ all pass, including "commit with no single-shot blob and no chunks returns 422
audio_upload_failed" (145–153) and the reassembly/single-shot-equality tests
(94–143).

### Step 5: Keep the commit hold proportional without a blob

In `commit_estimate` (`scribe_sessions_controller.rb:271-276`), when there is no
attached blob but chunks exist, estimate seconds from the **summed chunk
byte-size** using `AudioDuration`'s byte-size heuristic
(`ESTIMATE_BYTES_PER_SECOND = 16_000.0`) so the hold stays roughly proportional
for long recordings. Keep the 1-minute floor. Target shape:
```ruby
def commit_estimate(session)
  blob = session.audio_files.first
  seconds =
    if blob
      Scribe::AudioDuration.for_blob(blob).seconds.to_f
    else
      chunk_bytes = session.audio_chunks.with_attached_data
                           .sum { |c| c.data.blob&.byte_size.to_i }
      chunk_bytes / Scribe::AudioDuration::ESTIMATE_BYTES_PER_SECOND
    end
  minutes = [ seconds / 60.0, COMMIT_ESTIMATE_MIN_MINUTES ].max
  (minutes * COMMIT_ESTIMATE_RATE_PER_MINUTE).round(6)
end
```
Chosen approach (documented per the design): sum `audio_chunks` byte-size via
the same `with_attached_data.sum { c.data.blob&.byte_size.to_i }` pattern the
controller already uses at `:121-122`, then divide by
`AudioDuration::ESTIMATE_BYTES_PER_SECOND`. This reuses the estimator's constant
without invoking its private `estimate_seconds` (which needs a blob). No chunks
and no blob is unreachable here — Step 4's guard already 422'd that case before
`commit_estimate` is called. The 1-minute floor keeps a short/empty estimate
positive, unchanged.

**Verify**: `ASDF_RUBY_VERSION=3.4.1 bin/rails test test/integration/api/v2/audio_chunks_test.rb`
→ all pass (the chunked-commit tests exercise this branch and still reach
`:accepted`; accounts without an `AccountCredit` are unlimited so the hold is a
no-op for them).

### Step 6: Add a chunked-only pipeline test

See Test plan for the exact case. Add it to
`test/integration/api/v2/audio_chunks_test.rb`.

**Verify**: `ASDF_RUBY_VERSION=3.4.1 bin/rails test test/integration/api/v2/audio_chunks_test.rb`
→ all pass, including the new test.

## Test plan

- **Existing tests that MUST still pass** in
  `test/integration/api/v2/audio_chunks_test.rb` (jobs run inline, so
  commit → job → assemble → ASR happen synchronously and `audio_files` ends
  attached):
  - "commit reassembles chunks into one blob equal to the concatenation and runs
    the pipeline" (94–110) — asserts `@session.audio_files.attached?`,
    `@session.audio_files.first.download == "hello world"`, and a transcript
    exists.
  - "resume-then-commit yields the same persisted transcript as a single-shot
    upload of the concatenated bytes" (112–143) — asserts the reassembled blob
    equals the concatenation AND that the chunked transcript equals the
    single-shot transcript.
  - "commit with no single-shot blob and no chunks returns 422
    audio_upload_failed" (145–153) — asserts `422`, no transcript, no attachment.
- **New test to add** — "chunked-only commit attaches audio_files and produces a
  transcript when NO commit-time blob was uploaded". Structure it after the
  existing "commit reassembles chunks…" test (94–110):
  - Upload two or three chunks via `chunk_upload` to `chunks_url` with `@auth`.
  - Assert `@session.reload.audio_files.attached?` is **false** immediately after
    the last chunk POST but before commit (proves assembly did not happen at
    upload/commit ingress; it is deferred to the job).
  - POST `commit_url` with `@auth`; assert `:accepted`.
  - After commit (job ran inline): assert `@session.reload.audio_files.attached?`
    is now true, the blob equals the ordered concatenation of the chunk bytes,
    and `@session.transcript` is present — proving the pipeline assembled and
    transcribed from chunks with no commit-time blob.
  - (The single-shot path is already covered unchanged by the equality test at
    112–143; no new single-shot test is needed.)
- Structural pattern: reuse the private helpers `chunk_upload`, `commit_url`,
  `chunks_url`, and the `stub_openai!` setup already in the file.
- Verification: `ASDF_RUBY_VERSION=3.4.1 bin/rails test test/integration/api/v2/audio_chunks_test.rb`
  → all pass, including the 1 new test.

## Done criteria

Machine-checkable. ALL must hold:

- [ ] `app/services/scribe/audio_source.rb` exists and defines `Scribe::AudioSource.with_audio`
- [ ] `Orchestrator#with_audio` delegates to `Scribe::AudioSource` — `grep -n "AudioSource" app/services/scribe/orchestrator.rb` returns a match
- [ ] The Orchestrator no longer downloads an assembled blob for ASR — `grep -n "blob.download" app/services/scribe/orchestrator.rb` returns no match
- [ ] `commit` no longer assembles — `grep -n "ChunkAssembler" app/controllers/api/v2/scribe_sessions_controller.rb` returns no match
- [ ] The no-audio guard rejects only when blob AND chunks are both absent — `grep -n "audio_chunks.exists?" app/controllers/api/v2/scribe_sessions_controller.rb` shows it inside the `!... .exists?` guard
- [ ] `commit_estimate` uses `AudioDuration::ESTIMATE_BYTES_PER_SECOND` for the no-blob branch — `grep -n "ESTIMATE_BYTES_PER_SECOND" app/controllers/api/v2/scribe_sessions_controller.rb` returns a match
- [ ] `ASDF_RUBY_VERSION=3.4.1 bin/rails test test/integration/api/v2/audio_chunks_test.rb` passes, including the new chunked-only pipeline test
- [ ] `ASDF_RUBY_VERSION=3.4.1 bin/rails test` exits 0 with 0 failures and 0 errors
- [ ] `ASDF_RUBY_VERSION=3.4.1 bin/rubocop` reports no offenses
- [ ] No files outside the in-scope list are modified (`git status`)
- [ ] A new row for plan 020 is ADDED to `plans/README.md` (the table currently ends at 019); exact values: `| 020 | Assemble chunked audio once, transcribe without a second download | P2 | M | — | TODO |`. If a reviewer maintains the index, skip this.

## STOP conditions

Stop and report back (do not improvise) if:

- The code at the cited controller/service lines does not match "Current state"
  (the codebase has drifted since this plan was written).
- Removing commit-time assembly breaks `commit_estimate` for accounts with an
  `AccountCredit` in a way the existing tests cannot cover (e.g. the hold now
  under-charges to zero, or an insufficient-credit account that used to be
  blocked now passes) — surface it rather than adjusting the metering math,
  which is out of scope.
- `AudioSource` on chunks cannot reproduce a byte-identical concatenation (the
  "reassembled audio must equal the concatenation" assertion at 126–127 fails) —
  do not paper over it; report the divergence.
- Anything other than the audio **source** needs to change in the ASR call path
  (`AsrStage`, `ConfigResolver`, duration measurement) to make tests pass.
- A step's verification fails twice after a reasonable fix attempt.

## Maintenance notes

For the human/agent who owns this after the change lands:

- **Observable production change**: on the chunked path, `session.audio_files`
  now attaches **during the processing job**, not at `commit`. A client polling
  `GET /api/v2/scribe_sessions/:id` between commit and job completion will not
  see an attached blob yet. The single-shot path is unchanged (blob attaches at
  upload). No test asserts a commit-time attachment on the chunked path, but any
  new client code that assumes one must be updated.
- Plan 022 (incremental ASR) turns whole-file ASR into a **fallback**; this plan
  optimizes that fallback, so the `AudioSource` seam is the seam plan 022 will
  build on. Keep `with_audio(session)` as the single full-audio entry point.
- A reviewer should confirm (1) no `blob.download` remains on the ASR feed path
  (grep `orchestrator.rb`) — the assembled tempfile is both attached and fed to
  ASR directly, so there is no second full-file GET for transcription — and
  (2) the reassembled blob still equals the ordered concatenation of chunk bytes
  (the two invariant tests at 94–143), and (3) the double `tmp.rewind` (before
  attach's read and again before yield) is intact, since a missing second rewind
  silently sends empty audio to ASR.
- `ChunkAssembler` is retained and now driven from the processing path (via
  `AudioSource`) rather than from `commit`; its unit test
  `test/services/scribe/chunk_assembler_test.rb` stays as-is. It is NOT dead code
  and should not be deleted.
- The no-blob commit estimate reuses `AudioDuration::ESTIMATE_BYTES_PER_SECOND`
  (16_000 B/s) — if that constant is retuned for duration billing, the commit
  hold's proportionality moves with it, which is intended.
