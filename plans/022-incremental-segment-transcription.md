# Plan 022: Transcribe standalone audio segments incrementally as they arrive, through the provider-agnostic ASR seam, and build the final transcript by concatenation with no end-of-session re-download

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, add a new row for this plan (022) to
> the index table in `plans/README.md` — the table currently ends at 019, so
> append a row; do not overwrite an existing one. Use exactly:
> `| 022 | Incremental per-segment transcription through the provider seam | P2 | L | 020, 021 (soft) | TODO |`
> Skip this if a reviewer dispatched you and told you they maintain the index.
>
> **Drift check (run first)**:
> `git diff --stat 58fd6a5..HEAD -- app/controllers/api/v2/scribe_sessions_controller.rb app/models/scribe_session.rb app/models/scribe_audio_chunk.rb app/serializers/scribe_session_serializer.rb app/services/scribe/orchestrator.rb app/services/scribe/asr_stage.rb app/services/llm/config_resolver.rb app/jobs/process_scribe_session_job.rb config/routes.rb db/migrate`
> If any in-scope file changed since this plan was written, compare the
> "Current state" excerpts against the live code before proceeding; on a
> mismatch, treat it as a STOP condition.

## Status

- **Priority**: P2
- **Effort**: L
- **Risk**: MED-HIGH
- **Depends on**: plans/020-*.md (soft — shares the audio path), plans/021-*.md (soft — shares the serializer transcript field)
- **Category**: perf
- **Planned at**: commit `58fd6a5`, 2026-07-11 (all "Current state" excerpts
  were captured against HEAD `58fd6a5`).

## Why this matters

Today ASR runs exactly once, on the whole reassembled audio blob, and only
after commit — see `Scribe::Orchestrator#ensure_transcript!`
(`app/services/scribe/orchestrator.rb:63-93`), which downloads the entire blob
into a tempfile (`with_audio`, `:321-334`) and makes a single ASR call. So the
latency from "stop recording" to "transcript ready" is bounded by transcribing
the *entire* recording, and the whole file must be re-downloaded to feed the
model. Because the storage recording is one continuous file (design choice A),
individual storage chunks (`ScribeAudioChunk`) are **not** independently
decodable, so they cannot be transcribed piecemeal. The SDK therefore uploads
**separate, standalone, short transcription SEGMENTS** that ARE independently
decodable (see the SDK plan). This plan transcribes each segment on arrival
through the **same** provider seam clients already configure per-account
(`Llm::ConfigResolver` + `Scribe::AsrStage`), exposes a growing live transcript
during recording, and at commit assembles the final transcript from the ordered
segment texts — with no whole-file ASR re-download in the happy path. Model
choice stays a pure config swap (Whisper today, anything later) via
`ModelAssignment`/`ConfigResolver`; nothing about ASR is hardcoded here.

**Storage recording is always present at commit; segments are an ASR overlay,
not a substitute.** The continuous, playable STORAGE recording (design choice A:
one file, uploaded via `audio/chunks` or single-shot `audio`) is ALWAYS
uploaded and assembled at commit — the transcription SEGMENTS stream exists
ONLY to drive live/incremental ASR and to assemble the transcript text; it does
NOT replace the storage upload. The two streams are independent (dual-upload by
design). The unchanged commit action still correctly `422`s when there is
neither a storage blob NOR chunks — that guard stays out of scope and unchanged.
So every real session that reaches commit has `session.audio_files` populated
from the storage stream, regardless of the segment overlay.

## Current state

- `app/controllers/api/v2/scribe_sessions_controller.rb:89-140` — `audio_chunks`
  is the exact pattern the new `audio_segments` action mirrors: reachable under
  either credential via `find_session`, guarded by `reject_expired`, requires a
  `seq` and a file part, normalizes the content-type with `base_audio_type`,
  allowlists against `ScribeSession::ALLOWED_AUDIO_TYPES`, enforces a per-part
  ceiling, `find_or_initialize_by(seq:)`, attaches, `save!`, and rescues
  `ActiveRecord::RecordNotUnique` as an idempotent success:
  ```ruby
  chunk = session.audio_chunks.find_or_initialize_by(seq: seq)
  chunk.content_type = content_type
  chunk.final = true if ActiveModel::Type::Boolean.new.cast(params[:final])
  chunk.data.attach(upload)
  chunk.save!
  session.update!(status: "uploading") if session.created?

  render json: { received: seq }, status: :ok
  rescue ActiveRecord::RecordNotUnique
    # A concurrent upload of the same seq already stored this part. Per-seq
    # upload is idempotent, so treat the race as success.
    render json: { received: seq }, status: :ok
  ```
- `app/controllers/api/v2/scribe_sessions_controller.rb:303-315` — `find_session`
  resolves the session under an account token OR a scoped session token, 404ing
  a foreign id. `reject_expired` (`:321-326`) renders the shared 410 envelope.
  `base_audio_type` (`:331-333`) strips MIME parameters. `MAX_CHUNK_BYTES`
  (`:12`) is `8.megabytes`.
- `app/models/scribe_audio_chunk.rb:1-8` — the model pattern to mirror:
  ```ruby
  class ScribeAudioChunk < ApplicationRecord
    belongs_to :scribe_session
    has_one_attached :data

    validates :seq, presence: true,
              numericality: { only_integer: true, greater_than_or_equal_to: 0 },
              uniqueness: { scope: :scribe_session_id }
  end
  ```
- `app/models/scribe_session.rb:19-27` — associations. Note it already has
  `has_many :audio_chunks, class_name: "ScribeAudioChunk", dependent: :destroy`
  and `has_one :transcript, dependent: :destroy`. `ALLOWED_AUDIO_TYPES` and
  `MAX_AUDIO_BYTES = 25.megabytes` are at `:34-37`.
- `app/services/scribe/orchestrator.rb:63-93` — `ensure_transcript!` runs ASR
  once on the whole blob and persists a `Transcript`. It returns early when a
  transcript already exists (`:64`). `persist_transcript!` (`:99-108`) writes
  `text/language/duration_seconds/provider/model`. `meter` (`:235-243`) and
  `record_and_deduct` (`:252-264`) are the best-effort ASR/structuring metering
  path; `dedupe_key_for` (`:271-277`) builds `"#{session.id}:#{function}"` for a
  session-level meter. `with_audio`/`audio_extension` (`:321-351`) download the
  blob to a tempfile with a REAL audio extension via the `CONTENT_TYPE_EXT` map
  (never `.bin`, which Whisper rejects).
- `app/services/scribe/asr_stage.rb:9-35` — the provider-agnostic ASR seam.
  `Scribe::AsrStage.new(config:).call(audio_io, language:, mode:, audio_seconds:)`
  returns a `Result` struct with `text/language/duration_seconds/model/provider/usage/raw`.
  **Reuse verbatim.**
- `app/services/llm/config_resolver.rb:9-11` —
  `Llm::ConfigResolver.call(function:, page:, account:)` resolves the per-account
  ASR config. **Reuse verbatim** with `function: :asr, account: session.account`.
- `app/services/scribe/audio_duration.rb:14` —
  `Scribe::AudioDuration.for_blob(blob, file: nil)` returns a `Result` with
  `.seconds` (Float). Use it for a segment's `audio_seconds`.
- `app/jobs/process_scribe_session_job.rb:17-34` — the job pattern: load by id,
  return if nil, do work, rescue `StandardError`, log, and swallow (do NOT
  re-raise — no infinite retry). The test env runs jobs with the `:inline`
  ActiveJob adapter (synchronously), so an enqueued job has already run by the
  time the enqueuing request returns.
- `app/serializers/scribe_session_serializer.rb:9-18` — `as_json` returns
  `id/status/mode/language/expires_at/outputs`. There is **no** top-level
  `transcript` field yet (plan 021 adds it; if 021 has not landed, this plan
  adds it). This is a plain-Ruby serializer, so a computed field is trivial.
- `config/routes.rb:66-79` — the v2 `scribe_sessions` member routes, including
  the string-path pattern this plan copies:
  ```ruby
  resources :scribe_sessions, only: [ :create, :show, :index ] do
    member do
      post :audio
      post :commit
      post :tokens
      post "audio/chunks", to: "scribe_sessions#audio_chunks"
      get "audio/status", to: "scribe_sessions#audio_status"
    end
  end
  ```
- `app/models/transcript.rb` — `belongs_to :scribe_session` only; columns are
  `text/language/duration_seconds/provider/model` (see `persist_transcript!`).
- `test/integration/api/v2/audio_chunks_test.rb:280-302` — `stub_openai!` stubs
  the ASR (`/v1/audio/transcriptions`) and chat (`/v1/chat/completions`)
  endpoints with WebMock. The ASR stub returns
  `{ text: "patient reports headache", language: "en" }`. Reuse this pattern to
  count per-segment ASR calls.
- Latest migration is `db/migrate/20260710130000_create_scribe_audio_chunks.rb`
  — the house migration style (`ActiveRecord::Migration[8.0]`, `t.references`
  with `foreign_key: true`, a unique composite `add_index`):
  ```ruby
  class CreateScribeAudioChunks < ActiveRecord::Migration[8.0]
    def change
      create_table :scribe_audio_chunks do |t|
        t.references :scribe_session, null: false, foreign_key: true
        t.integer :seq, null: false
        t.boolean :final, null: false, default: false
        t.string :content_type
        t.timestamps
      end
      add_index :scribe_audio_chunks, [ :scribe_session_id, :seq ], unique: true
    end
  end
  ```

## Commands you will need

| Purpose        | Command                                                                                   | Expected on success |
|----------------|-------------------------------------------------------------------------------------------|---------------------|
| Migrate        | `ASDF_RUBY_VERSION=3.4.1 bin/rails db:migrate`                                             | exit 0, schema updated |
| Segments test  | `ASDF_RUBY_VERSION=3.4.1 bin/rails test test/integration/api/v2/audio_segments_test.rb`    | all pass            |
| Chunks test    | `ASDF_RUBY_VERSION=3.4.1 bin/rails test test/integration/api/v2/audio_chunks_test.rb`      | all pass (unchanged)|
| Full tests     | `ASDF_RUBY_VERSION=3.4.1 bin/rails test`                                                   | 0 failures          |
| Lint           | `ASDF_RUBY_VERSION=3.4.1 bin/rubocop`                                                      | no offenses         |

(Test env uses the `:inline` ActiveJob adapter — jobs run synchronously inside
the request, so `TranscribeSegmentJob` has finished by the time the segments
POST returns.)

## Scope

**In scope** (the only files you should create/modify):
- `db/migrate/<timestamp>_create_scribe_transcript_segments.rb` (create)
- `app/models/scribe_transcript_segment.rb` (create)
- `app/models/scribe_session.rb` (add association + `live_transcript`)
- `app/services/scribe/audio_tempfile.rb` (create — the shared extension/tempfile helper)
- `app/services/scribe/orchestrator.rb` (segments-first `ensure_transcript!`; reuse the new helper)
- `app/jobs/transcribe_segment_job.rb` (create)
- `app/controllers/api/v2/scribe_sessions_controller.rb` (add `audio_segments` action)
- `config/routes.rb` (add the segments route)
- `app/serializers/scribe_session_serializer.rb` (source the top-level transcript field)
- `db/schema.rb` (regenerated by the migration — commit it)
- `test/integration/api/v2/audio_segments_test.rb` (create)

**Out of scope** (do NOT touch, even though they look related):
- The ASR/structuring model seam internals — `app/services/scribe/asr_stage.rb`,
  `app/services/llm/config_resolver.rb`, `app/services/llm/*`. Reuse them
  verbatim; changing them is a STOP condition.
- The storage-chunk path (`ScribeAudioChunk`, `Scribe::ChunkAssembler`,
  `audio_chunks`/`audio_status` actions) and the assembled playback blob
  (`audio_files`) — segments are a SEPARATE stream; leave storage untouched.
- The FE/SDK segment uploader — a separate plan.
- The commit pre-flight billing hold
  (`Metering::QuotaGuard.hold!` at `scribe_sessions_controller.rb:203`) — leave
  it; it simply over-estimates now. Do NOT add a hold to the segment path.

## Git workflow

- Branch: `advisor/022-incremental-segment-transcription` (or the repo's
  branch-naming convention if one is evident — current work is on
  `feature/model-agnostic-ai`).
- Commit per step or per logical unit. Match the repo's log style (short
  imperative subject, e.g. `Add scribe transcript segment model and migration`).
- Do NOT push or open a PR unless the operator instructed it.

## Steps

### Step 1: Migration + `ScribeTranscriptSegment` model

Create the migration. Name it with a timestamp strictly after the latest
existing migration (`20260710130000`), e.g.
`db/migrate/20260711120000_create_scribe_transcript_segments.rb`. Mirror the
`scribe_audio_chunks` migration style exactly:
```ruby
class CreateScribeTranscriptSegments < ActiveRecord::Migration[8.0]
  def change
    create_table :scribe_transcript_segments do |t|
      t.references :scribe_session, null: false, foreign_key: true
      t.integer :seq, null: false
      t.string :content_type
      t.text :text
      t.string :language
      t.string :status, null: false, default: "pending"
      t.string :provider
      t.string :model
      t.float :duration_seconds
      t.datetime :transcribed_at
      t.timestamps
    end
    add_index :scribe_transcript_segments, [ :scribe_session_id, :seq ], unique: true
  end
end
```

Create `app/models/scribe_transcript_segment.rb`, mirroring
`ScribeAudioChunk` and adding the status enum + attachment:
```ruby
class ScribeTranscriptSegment < ApplicationRecord
  belongs_to :scribe_session
  has_one_attached :data

  enum :status, {
    pending: "pending",
    transcribing: "transcribing",
    done: "done",
    failed: "failed"
  }, prefix: true

  validates :seq, presence: true,
            numericality: { only_integer: true, greater_than_or_equal_to: 0 },
            uniqueness: { scope: :scribe_session_id }
end
```
(Use `prefix: true` so the predicates read `status_done?`/`status_failed?` and
never collide with any other enum. Note the plain `status` column carries the
enum; the model reads/writes the string values above.)

Add to `app/models/scribe_session.rb` (next to the `audio_chunks` association at
`:24`):
```ruby
has_many :transcript_segments, class_name: "ScribeTranscriptSegment", dependent: :destroy
```

**Verify**: `ASDF_RUBY_VERSION=3.4.1 bin/rails db:migrate` → exit 0; then
`ASDF_RUBY_VERSION=3.4.1 bin/rails runner "ScribeTranscriptSegment.new(seq: 0, status: 'pending'); puts ScribeSession.new.respond_to?(:transcript_segments)"`
→ prints `true` with no error.

### Step 2: Extract the shared `Scribe::AudioTempfile` helper

The tempfile-with-real-extension logic lives privately in
`Orchestrator#with_audio`/`#audio_extension` (`orchestrator.rb:321-351`). The
segment job needs the identical logic, so extract it into a shared service
rather than duplicating the `.bin` bug it exists to prevent.

Create `app/services/scribe/audio_tempfile.rb`:
```ruby
module Scribe
  # Downloads an ActiveStorage blob into a Tempfile that carries a REAL audio
  # extension. Provider ASR endpoints (e.g. OpenAI Whisper) infer the audio
  # format from the file EXTENSION, so the tempfile must never be ".bin" (which
  # Whisper rejects with "Invalid file format"). Prefer the blob filename's
  # extension; fall back to the content-type map; default ".mp3".
  #
  # Yields the rewound Tempfile and always closes it. Extracted from
  # Orchestrator#with_audio so the per-segment job and the whole-file path share
  # one implementation.
  class AudioTempfile
    CONTENT_TYPE_EXT = {
      "audio/mpeg" => ".mp3", "audio/mp3" => ".mp3", "audio/mp4" => ".mp4",
      "audio/wav" => ".wav", "audio/x-wav" => ".wav", "audio/webm" => ".webm",
      "audio/ogg" => ".ogg", "audio/m4a" => ".m4a", "audio/aac" => ".aac"
    }.freeze

    def self.with(blob, &block)
      new(blob).call(&block)
    end

    def self.extension(blob)
      from_name = File.extname(blob.filename.to_s).downcase
      return from_name if from_name.present?

      CONTENT_TYPE_EXT[blob.content_type] || ".mp3"
    end

    def initialize(blob)
      @blob = blob
    end

    def call
      tmp = Tempfile.new([ "audio", self.class.extension(@blob) ])
      tmp.binmode
      tmp.write(@blob.download)
      tmp.rewind
      begin
        yield tmp
      ensure
        tmp.close!
      end
    end
  end
end
```

Refactor `Orchestrator#with_audio` (`orchestrator.rb:321-334`) and
`#audio_extension`/`CONTENT_TYPE_EXT` (`:340-351`) to delegate to the helper.
`with_audio` must keep its `blob.nil? → yield(nil)` behavior:
```ruby
def with_audio
  blob = session.audio_files.first
  return yield(nil) if blob.nil?

  Scribe::AudioTempfile.with(blob) { |tmp| yield tmp }
end
```
Delete the now-dead `audio_extension` method and `CONTENT_TYPE_EXT` constant
from the orchestrator (they live in the helper now).

**Verify**: `ASDF_RUBY_VERSION=3.4.1 bin/rails test test/integration/api/v2/scribe_sessions_test.rb test/integration/api/v2/audio_chunks_test.rb`
→ all pass (the whole-file ASR path is unchanged in behavior);
`grep -n "CONTENT_TYPE_EXT" app/services/scribe/orchestrator.rb` → no matches.

### Step 3: `TranscribeSegmentJob`

Create `app/jobs/transcribe_segment_job.rb`. Load the segment, then **atomically
claim it** so only ONE runner ever transcribes a given segment (the async job
and the commit-time inline pass can both target a trailing segment — see Step 7).
The claim is a single conditional `UPDATE`: flip `pending`/`failed` → `transcribing`
via `update_all`, and bail if it affected zero rows (another runner already
claimed it, or it is already `done`). Then download the segment's `data` blob via
the Step-2 helper, resolve the per-account ASR config, run the ASR seam, store
the result, mark `done`, and meter `:asr` best-effort (record+deduct only —
**never** a hold). On ASR failure, mark `failed`, log, and swallow (do not
re-raise — no infinite retry, matching `ProcessScribeSessionJob`).
```ruby
class TranscribeSegmentJob < ApplicationJob
  def perform(segment_id)
    segment = ScribeTranscriptSegment.find_by(id: segment_id)
    return if segment.nil?

    # ATOMIC claim: only one runner may move this segment into "transcribing".
    # A segment already "transcribing" or "done" matches zero rows here and is
    # skipped, so the async job and the commit-time inline pass can never both
    # call the provider for the same segment.
    claimed = ScribeTranscriptSegment
              .where(id: segment.id, status: %w[pending failed])
              .update_all(status: "transcribing", updated_at: Time.current)
    return if claimed.zero?

    segment.reload
    session = segment.scribe_session

    config = Llm::ConfigResolver.call(function: :asr, account: session.account)
    blob = segment.data.blob

    result = Scribe::AudioTempfile.with(blob) do |io|
      duration = Scribe::AudioDuration.for_blob(blob, file: io).seconds
      Scribe::AsrStage.new(config: config).call(
        io,
        language: session.language,
        mode: :transcribe,
        audio_seconds: duration
      )
    end

    segment.update!(
      text: result.text,
      language: result.language,
      provider: result.provider,
      model: result.model,
      duration_seconds: result.duration_seconds,
      transcribed_at: Time.current,
      status: "done"
    )

    meter_segment(session, segment, result)
  rescue StandardError => e
    segment&.update(status: "failed")
    Rails.logger.error("TranscribeSegmentJob failed for segment=#{segment_id}: #{e.class}: #{e.message}")
    nil
  end

  private

  # Best-effort ASR metering for one segment: record a usage_event and deduct it.
  # Mirrors Orchestrator#record_and_deduct but with a per-segment dedupe_key so a
  # retried job never double-charges. CRITICAL: this is record+deduct only — it
  # must NEVER call Metering::QuotaGuard.hold!/hard-block. A credit check must not
  # reject a segment mid-recording; billing is settled at commit's existing hold.
  def meter_segment(session, segment, result)
    event = Metering::UsageRecorder.record(
      account: session.account,
      function: :asr,
      result: as_llm_result(result),
      api_token: session.api_token,
      scribe_session: session,
      dedupe_key: "#{session.id}:segment:#{segment.id}:asr"
    )
    Metering::QuotaGuard.deduct!(event)
  rescue StandardError => e
    Rails.logger.error("TranscribeSegmentJob metering failed for segment=#{segment.id}: #{e.class}: #{e.message}")
    nil
  end

  # AsrStage::Result does not respond to #latency_ms; adapt it to the Llm::Result
  # contract Metering::UsageRecorder consumes (matches Orchestrator#as_llm_result).
  def as_llm_result(result)
    Llm::Result.new(
      text: result.text,
      structured: nil,
      model: result.model,
      provider: result.provider,
      usage: result.usage,
      latency_ms: nil,
      finish_reason: nil,
      raw: result.respond_to?(:raw) ? result.raw : nil
    )
  end
end
```
Confirm the metering call shape against `Metering::UsageRecorder.record`
(`app/services/metering/usage_recorder.rb:8-9`) and
`Metering::QuotaGuard.deduct!` (`app/services/metering/quota_guard.rb:48`) — the
keyword args above mirror `Orchestrator#record_and_deduct`
(`orchestrator.rb:252-264`). If `QuotaGuard` cannot `deduct!` without a prior
`hold!`, that is a STOP condition (see STOP conditions).

**Verify**: `ASDF_RUBY_VERSION=3.4.1 bin/rubocop app/jobs/transcribe_segment_job.rb app/services/scribe/audio_tempfile.rb`
→ no offenses. (End-to-end behavior is verified by the Step-7 tests.)

### Step 4: `POST /api/v2/scribe_sessions/:id/audio/segments` action + route

Add the `audio_segments` action to
`app/controllers/api/v2/scribe_sessions_controller.rb`, mirroring
`audio_chunks` (`:95-140`). Requirements:
- Reachable under account OR session token via `find_session`; guard with
  `reject_expired`.
- Require `seq` (>= 0) and a `segment` file part.
- Gate behind the incremental feature flag (Step 6): when OFF, return `404`
  (`session_not_found`) so the surface simply does not exist.
- Normalize + allowlist the content-type via `base_audio_type` against
  `ScribeSession::ALLOWED_AUDIO_TYPES`; enforce `MAX_CHUNK_BYTES` per part.
- Segments are a SEPARATE stream from storage chunks and are NOT counted against
  the 25MB storage cap. Give them their own per-session ceiling by summing the
  OTHER segments' bytes against `ScribeSession::MAX_AUDIO_BYTES` (reused as a
  segment-total cap). Dual-upload means ~2x audio bytes **by design**.
- `find_or_initialize_by(seq:)`, attach `data`, `save!`, rescue
  `RecordNotUnique` as idempotent `200 { received: seq }`.
- On successful store, enqueue `TranscribeSegmentJob.perform_later(segment.id)`.

Target shape:
```ruby
# POST /api/v2/scribe_sessions/:id/audio/segments
#
# Accepts one STANDALONE, independently-decodable transcription segment: a `seq`
# and a `segment` file part. Each segment is transcribed on arrival by
# TranscribeSegmentJob through the same provider ASR seam. Separate from the
# storage `audio/chunks` stream and from the 25MB storage cap — dual-upload
# doubles audio bytes by design. Re-POSTing a seq is idempotent.
def audio_segments
  return render_error(code: "session_not_found", message: "Scribe session not found", status: :not_found) unless Scribe::Incremental.enabled?

  session = find_session
  return unless session
  return if reject_expired(session)

  seq = params.require(:seq).to_i
  upload = params.require(:segment)

  if seq.negative?
    render_error(code: "validation_error", message: "seq must be >= 0", status: :unprocessable_entity)
    return
  end
  if upload.respond_to?(:size) && upload.size > MAX_CHUNK_BYTES
    render_error(code: "validation_error", message: "segment too large", status: :unprocessable_entity)
    return
  end
  content_type = base_audio_type(upload.content_type).presence || "audio/webm"
  unless ScribeSession::ALLOWED_AUDIO_TYPES.include?(content_type)
    render_error(code: "validation_error", message: "unsupported audio content type: #{upload.content_type}", status: :unprocessable_entity)
    return
  end
  other_bytes = session.transcript_segments.where.not(seq: seq)
                       .with_attached_data.sum { |s| s.data.blob&.byte_size.to_i }
  if other_bytes + upload.size.to_i > ScribeSession::MAX_AUDIO_BYTES
    render_error(code: "audio_upload_failed", message: "total segment audio exceeds #{ScribeSession::MAX_AUDIO_BYTES} bytes", status: :unprocessable_entity)
    return
  end

  segment = session.transcript_segments.find_or_initialize_by(seq: seq)
  segment.content_type = content_type
  segment.data.attach(upload)
  segment.save!
  session.update!(status: "uploading") if session.created?

  TranscribeSegmentJob.perform_later(segment.id)

  render json: { received: seq }, status: :ok
rescue ActiveRecord::RecordNotUnique
  render json: { received: seq }, status: :ok
end
```

Add the route in `config/routes.rb` next to `audio/chunks` (`:72`):
```ruby
post "audio/segments", to: "scribe_sessions#audio_segments"
```

**Verify**: `ASDF_RUBY_VERSION=3.4.1 bin/rails runner "puts Rails.application.routes.recognize_path('/api/v2/scribe_sessions/1/audio/segments', method: :post).inspect"`
→ includes `action: \"audio_segments\"`.

### Step 5: Live transcript on the session + serializer field

Add to `app/models/scribe_session.rb`:
```ruby
# The growing transcript during recording: the done segments' texts, in seq
# order, joined. Blank until the first segment finishes ASR.
def live_transcript
  transcript_segments.status_done.order(:seq).map(&:text).reject(&:blank?).join(" ")
end
```
(Use the enum scope `status_done` created by `prefix: true` in Step 1;
equivalent to `where(status: "done")`.)

In `app/serializers/scribe_session_serializer.rb`, source the top-level
`transcript` field (the field plan 021 adds; if 021 has not landed, add it now)
as the authoritative post-commit transcript when present, else the live
transcript during recording:
```ruby
def as_json(*)
  {
    id: @session.id,
    status: @session.status,
    mode: @session.mode,
    language: @session.language,
    transcript: transcript_text,
    expires_at: @session.expires_at,
    outputs: @session.scribe_outputs.map { |output| serialize_output(output) }
  }
end

private

# Post-commit the persisted Transcript is authoritative; during recording fall
# back to the growing live transcript assembled from done segments.
def transcript_text
  @session.transcript&.text.presence || @session.live_transcript.presence
end
```
(If plan 021 already added a `transcript` key with a different source
expression, reconcile: the value must be `session.transcript&.text` OR
`live_transcript`. Do not add a second `transcript` key.)

**Verify**: `ASDF_RUBY_VERSION=3.4.1 bin/rails runner "s=ScribeSession.new; puts s.respond_to?(:live_transcript); puts ScribeSessionSerializer.new(s).as_json.key?(:transcript)"`
→ prints `true` then `true`.

### Step 6: Feature flag `Scribe::Incremental`

Gate the incremental path behind a simple predicate so it can be rolled out and
disabled without a code change. Create a small predicate module (place it at
`app/services/scribe/incremental.rb`):
```ruby
module Scribe
  # Toggle for the incremental per-segment transcription path (plan 022).
  # OFF by default: the segments endpoint 404s and commit uses whole-file ASR.
  # Flip with ENV["SCRIBE_INCREMENTAL_ASR"] = "true" (or wire an account/system
  # setting here later without touching call sites).
  module Incremental
    def self.enabled?
      ActiveModel::Type::Boolean.new.cast(ENV["SCRIBE_INCREMENTAL_ASR"]).present?
    end
  end
end
```
This predicate gates BOTH the segments endpoint (Step 4) and the commit
segments-first branch (Step 7): when OFF, `ensure_transcript!` must ignore any
segments and use the whole-file path.

**Verify**: `ASDF_RUBY_VERSION=3.4.1 bin/rails runner "ENV['SCRIBE_INCREMENTAL_ASR']=nil; puts Scribe::Incremental.enabled?; ENV['SCRIBE_INCREMENTAL_ASR']='true'; puts Scribe::Incremental.enabled?"`
→ prints `false` then `true`.

### Step 7: Commit builds the transcript from segments (no whole-file ASR)

Change `Orchestrator#ensure_transcript!` (`orchestrator.rb:63-93`) so that when
the incremental flag is ON and the session HAS transcript segments, it builds
the `Transcript` from the ordered segment texts instead of re-downloading the
whole blob. Keep the early return for an already-persisted transcript
(idempotent re-commit). Behavior:
1. `return session.transcript if session.transcript.present?` (unchanged, `:64`).
2. If `Scribe::Incremental.enabled?` AND `session.transcript_segments.exists?`:
   - **Finish trailing segments without double-transcribing.** A trailing
     segment may already be in flight in an async `TranscribeSegmentJob`, so
     commit must NOT blindly re-invoke ASR on it. For each non-`done` segment:
     - If it is `transcribing`, WAIT for it to settle — a bounded poll (e.g. a
       few seconds, reloading the row) for it to reach `done` (or `failed`),
       rather than calling the provider again. The in-flight job owns it.
     - Only `pending`/`failed` segments are transcribed inline, via
       `TranscribeSegmentJob.perform_now(segment.id)` — which itself goes through
       the SAME atomic claim (Step 3), so if the async job grabs the row first,
       the inline call no-ops and simply waits. This makes the trailing finish
       deterministic without ever double-calling the provider. Reload the
       segments after.
   - **Safety net for gaps.** If, after the inline pass, ANY segment is
     `status_failed`, fall back to a single whole-file ASR pass over the
     assembled `audio_files` blob (the existing path below) so the transcript is
     complete — accept the rare re-download only in this failure case. This
     fallback re-transcribes for COMPLETENESS ONLY: it must **not** record a
     second `:asr` usage_event, because per-segment jobs already metered `:asr`
     for the segments that succeeded. Distinct dedupe keys (`"<sid>:segment:…:asr"`
     vs. `"<sid>:asr"`) do NOT prevent a double-charge — they are different keys,
     so both would deduct. The whole-file fallback therefore SKIPS metering
     (`transcript_from_whole_file!(meter: false)`), accepting the already-metered
     segments as the billed quantity and a small under-bill for the failed gap.
   - Otherwise assemble from the done segments (ordered by `seq`):
     - `text` = the segment texts joined with `" "` (reuse `live_transcript`'s
       join, i.e. `segments.map(&:text).reject(&:blank?).join(" ")`).
     - `duration_seconds` = sum of segment `duration_seconds`.
     - `provider`/`model` = from the segments (first present).
     - `language` = first non-null segment `language`.
   - Persist via a `Transcript.create!` with those fields. Do **NOT** re-meter
     `:asr` for the assembled segments — each was already metered by its job
     (per-segment dedupe_key). Only the inline-finished segments meter, and they
     do so via their own job path with their own dedupe_key, so no double-charge.
3. Else (no segments, or flag OFF): keep the existing whole-file ASR path exactly
   (`:66-88`), including its single `meter(function: :asr, ...)` call.

Target shape (new private helpers; keep the whole-file path intact as the
`else`/fallback branch):
```ruby
def ensure_transcript!
  return session.transcript if session.transcript.present?

  if Scribe::Incremental.enabled? && session.transcript_segments.exists?
    return transcript_from_segments!
  end

  transcript_from_whole_file!
rescue Llm::Error => e
  mark_asr_failure!(e)
  @asr_failed = true
  nil
end

# Build the Transcript from the ordered segment texts, finishing any in-flight
# segment inline first. Falls back to a whole-file ASR pass ONLY if a segment is
# still failed after the inline retry (a coverage gap). No re-metering of
# already-metered segments — each job metered its own :asr with a per-segment
# dedupe_key.
def transcript_from_segments!
  session.transcript_segments.where.not(status: "done").find_each do |seg|
    if seg.status_transcribing?
      # An async job already claimed this segment — WAIT for it to settle rather
      # than re-invoking the provider (double-transcription guard).
      wait_for_segment(seg)
    else
      # pending/failed: transcribe inline. perform_now goes through the SAME
      # atomic claim, so if the async job wins the race this call no-ops.
      TranscribeSegmentJob.perform_now(seg.id)
    end
  end
  segments = session.transcript_segments.reload.order(:seq).to_a

  # COMPLETENESS-ONLY fallback: if a segment is still failed, re-transcribe the
  # whole file for coverage, but do NOT record a second :asr usage_event — the
  # already-metered segments are accepted as the billed quantity (a small
  # under-bill for the failed-segment gap). See transcript_from_whole_file!.
  return transcript_from_whole_file!(meter: false) if segments.any? { |s| s.status_failed? }

  done = segments.select(&:status_done?)
  Transcript.create!(
    scribe_session: session,
    text: done.map(&:text).reject(&:blank?).join(" "),
    language: done.map(&:language).compact.first,
    duration_seconds: done.sum { |s| s.duration_seconds.to_f },
    provider: done.map(&:provider).compact.first,
    model: done.map(&:model).compact.first
  )
end

# Bounded poll: give an in-flight async TranscribeSegmentJob a few seconds to
# reach a settled status (done/failed) before assembly. Never calls the provider.
def wait_for_segment(segment, timeout: 5.seconds, interval: 0.25)
  deadline = Time.current + timeout
  loop do
    segment.reload
    return segment unless segment.status_transcribing?
    break if Time.current >= deadline

    sleep interval
  end
  segment
end
```
Where `transcript_from_whole_file!(meter: true)` is the extracted body of today's
`:66-88` (config resolve → `with_audio`/`AsrStage` → `persist_transcript!` →
`meter(function: :asr, ...)`), returning the persisted transcript. It takes a
`meter:` keyword (default `true`): the normal flag-OFF / no-segments path calls
it with `meter: true` and meters exactly as before; the segment-failure safety
net calls it with `meter: false` so it skips the `meter(function: :asr, ...)`
call (the segments were already metered by their jobs — metering again would
double-charge). Move the `rescue Llm::Error` to the top-level `ensure_transcript!`
(as shown) so both paths share the ASR-failure handling.

Structuring downstream is unchanged: `Orchestrator#call` (`:35-54`) runs the
outputs against whatever transcript `ensure_transcript!` returns.

**Verify**: `ASDF_RUBY_VERSION=3.4.1 bin/rails test test/integration/api/v2/audio_chunks_test.rb`
→ all pass (flag OFF by default, so the whole-file path is byte-for-byte the
old behavior and the existing "single-shot vs chunked yield the same transcript"
test still holds).

### Step 8: Segment cleanup after commit (optional reclaim)

Segments are transient. `dependent: :destroy` (Step 1) already tears them down
when a session is deleted. Optionally, after `transcript_from_segments!` builds
the `Transcript`, delete the done segments to reclaim storage:
`session.transcript_segments.status_done.destroy_all` at the end of
`transcript_from_segments!` (after the `Transcript.create!`). Playback still
comes from the untouched assembled `audio_files` blob (choice A). If you add
this, make it best-effort (rescue+log) so a purge failure never fails commit.

**Verify**: `ASDF_RUBY_VERSION=3.4.1 bin/rails test test/integration/api/v2/audio_segments_test.rb`
→ the assembly test (Step 9) still asserts the persisted `Transcript.text`
equals the concatenation regardless of whether segments were purged.

## Test plan

Create `test/integration/api/v2/audio_segments_test.rb`, modeled structurally on
`test/integration/api/v2/audio_chunks_test.rb` (same setup: `create(:account)`,
`create(:user)`, `create(:api_token)`, `create(:scribe_session)`, a minted
session token via `Scribe::SessionToken.mint`, and `stub_openai!` from
`:280-302`). **Set `ENV["SCRIBE_INCREMENTAL_ASR"] = "true"` in `setup` and
restore it in `teardown`** (mirror the `OPENAI_ACCESS_TOKEN` save/restore at
`:22-30`) so the incremental path is exercised. Because the test env uses the
`:inline` ActiveJob adapter, `TranscribeSegmentJob` runs synchronously inside
each segments POST. Cover:

- **Happy path incremental assembly**: POST segment `seq: 0` then `seq: 1`
  (`audio/webm` uploads like `chunk_upload`); assert each `200 { received: seq }`
  and each segment row is `status == "done"` with non-blank `text` (the inline
  job ran). ALSO upload the STORAGE recording for the session so
  `session.audio_files` exists at commit (segments are an ASR overlay, NOT a
  substitute for the storage upload): either a single-shot `POST audio`, OR
  `POST audio/chunks` and rely on commit-time assembly. This mirrors a real
  client, which always uploads storage in addition to the two segments, and
  keeps the unchanged commit `audio_files` guard satisfied. GET
  `/api/v2/scribe_sessions/:id` and assert the top-level
  `transcript` grows (non-empty after seq 0, longer after seq 1). Then POST
  `commit`; assert the persisted `Transcript.text` equals the two segment texts
  joined with `" "`. Assert NO whole-file ASR pass ran when all segments were
  done — since `stub_openai!` returns the SAME text per call, assert the ASR
  endpoint was hit **once per segment** and NOT an extra time at commit, e.g.
  with `assert_requested :post, %r{/v1/audio/transcriptions}, times: 2` (two
  segments, no commit-time third call).
- **Idempotency**: re-POST `seq: 0` → `200`, and
  `session.transcript_segments.count` does not increase (one row per seq). Then
  POST `commit` again after completion → the pipeline does not re-transcribe done
  segments (the `Transcript.present?` early return holds; assert the ASR
  request count did not increase).
- **Failure safety net**: force one segment's ASR to fail (e.g. stub the ASR
  endpoint to `500` for one call, or stub `Scribe::AsrStage#call` to raise for
  a specific segment), leaving it `status == "failed"`. Also upload a real
  assembled blob for that session (single-shot `audio` or via chunks) so the
  whole-file fallback has a blob to read. POST `commit`; assert the persisted
  `Transcript` is still complete (the whole-file fallback ran) and the session
  reaches `completed`. ALSO assert the fallback did NOT double-charge: capture
  the `:asr` `usage_event` count for the session before `commit` and assert it is
  UNCHANGED after (the fallback runs with `meter: false`; only the successfully
  metered segments are billed).
- **Flag OFF preserves today's behavior**: with `ENV["SCRIBE_INCREMENTAL_ASR"]`
  unset, POST to `audio/segments` → `404` `session_not_found`; upload via the
  existing single-shot `audio` path + `commit` → transcript comes from the
  whole-file ASR path exactly as before (assert `completed` and a persisted
  `Transcript`).
- **Segment ASR failure never 500s the endpoint**: stub `TranscribeSegmentJob`'s
  ASR to raise; POST `audio/segments` still returns `200 { received: seq }` (the
  job swallows the error; the store succeeded) and the segment row is
  `status == "failed"`.
- **Ingress guards** (mirror the chunks tests): negative `seq` → `422`
  `validation_error`; disallowed content-type → `422` `validation_error`, no row
  stored; a codec-parameterized `audio/webm;codecs=opus` is accepted and stored
  as `audio/webm`.

Verification: `ASDF_RUBY_VERSION=3.4.1 bin/rails test test/integration/api/v2/audio_segments_test.rb`
→ all pass.

## Done criteria

Machine-checkable. ALL must hold:

- [ ] `ASDF_RUBY_VERSION=3.4.1 bin/rails db:migrate` exits 0 and `db/schema.rb` contains `create_table "scribe_transcript_segments"` with a unique index on `["scribe_session_id", "seq"]`
- [ ] `POST /api/v2/scribe_sessions/:id/audio/segments` route resolves to `audio_segments` (`grep -n "audio/segments" config/routes.rb` returns a match)
- [ ] `app/models/scribe_transcript_segment.rb`, `app/jobs/transcribe_segment_job.rb`, `app/services/scribe/audio_tempfile.rb`, and `app/services/scribe/incremental.rb` exist
- [ ] `grep -n "CONTENT_TYPE_EXT" app/services/scribe/orchestrator.rb` returns no matches (extension logic lives only in `Scribe::AudioTempfile`)
- [ ] `grep -n "hold!" app/jobs/transcribe_segment_job.rb` returns no matches (segment metering is record+deduct only, never a hold)
- [ ] When a segment fails and the whole-file safety net runs, NO second `:asr` usage_event is recorded — the fallback is invoked as `transcript_from_whole_file!(meter: false)` (distinct dedupe keys do NOT prevent the double-charge; the fallback SKIPPING metering does). Asserted in `audio_segments_test.rb` by checking the `:asr` usage_event count does not increase at commit in the failure case.
- [ ] No segment is transcribed twice: `TranscribeSegmentJob` claims via a conditional `update_all(status: "transcribing")` on `%w[pending failed]` and returns when it claims zero rows; commit WAITS on `transcribing` segments rather than re-invoking ASR
- [ ] With the flag ON, two segments assemble into a `Transcript.text` equal to their `" "`-joined texts, and the ASR endpoint is hit once per segment with NO extra whole-file call (asserted in `audio_segments_test.rb`)
- [ ] With the flag OFF, `audio/segments` returns `404` and commit uses the whole-file ASR path (asserted in `audio_segments_test.rb`)
- [ ] The segment failure safety net falls back to whole-file ASR and yields a complete transcript (asserted in `audio_segments_test.rb`)
- [ ] `ASDF_RUBY_VERSION=3.4.1 bin/rails test test/integration/api/v2/audio_chunks_test.rb test/integration/api/v2/scribe_sessions_test.rb` passes (existing storage-chunk + lifecycle behavior unchanged)
- [ ] `ASDF_RUBY_VERSION=3.4.1 bin/rails test` exits 0 with 0 failures
- [ ] `ASDF_RUBY_VERSION=3.4.1 bin/rubocop` reports no offenses
- [ ] No files outside the in-scope list are modified (`git status`)
- [ ] `plans/README.md` has a NEW row appended for plan 022 (the table currently ends at 019): `| 022 | Incremental per-segment transcription through the provider seam | P2 | L | 020, 021 (soft) | TODO |`

## STOP conditions

Stop and report back (do not improvise) if:

- The code at the cited controller/model/orchestrator/routes lines does not match
  "Current state" (the codebase drifted since `58fd6a5`).
- Metering a segment requires `Metering::QuotaGuard.hold!` — i.e. `deduct!`
  cannot record+settle without a prior hold, or the ASR meter path forces a
  hard-block. A credit check must NOT reject a segment mid-recording. Report what
  the metering API requires instead of adding a hold.
- `Metering::UsageRecorder.record`'s signature or the `Llm::Result` contract
  differs from what `Orchestrator#record_and_deduct` (`orchestrator.rb:252-264`)
  and `#as_llm_result` (`:282-293`) use — reconcile against the live code before
  wiring the job's meter.
- `ScribeSessionSerializer` cannot expose the computed `transcript` field (e.g.
  it was replaced by a framework serializer that forbids computed keys).
- The `Llm::ConfigResolver` / `Scribe::AsrStage` seam cannot be called from a
  per-segment job without modifying it — report exactly what blocks the reuse.
- You cannot make commit deterministically inline-finish trailing segments (e.g.
  `perform_now` is unavailable or segments cannot be reloaded to a settled
  state) — report rather than shipping a racy assembly.
- Plan 021 already added a top-level `transcript` field with an incompatible
  source expression you cannot reconcile without changing 021's contract.

## Maintenance notes

For the human/agent who owns this after the change lands:

- **Dual-upload doubles audio bytes by design**: the storage stream
  (`audio/chunks` → `audio_files`) and the segment stream (`audio/segments` →
  `transcript_segments`) both carry the recording. Segments have their own
  per-session ceiling (reusing `MAX_AUDIO_BYTES`) and are NOT counted against the
  25MB storage cap. If storage cost becomes a concern, purge done segments
  aggressively (Step 8) and/or lower the segment ceiling.
- **A reviewer must verify four invariants**: (1) ASR is metered exactly once per
  segment, and the whole-file failure fallback records NO additional `:asr`
  usage_event whenever any segment was already metered. Note the per-segment key
  `"<sid>:segment:<segid>:asr"` and the whole-file key `"<sid>:asr"` are DISTINCT,
  so the unique usage-event index does NOT dedupe them — both would deduct. The
  double-charge is prevented ONLY by the fallback SKIPPING metering
  (`transcript_from_whole_file!(meter: false)`), accepting the already-metered
  segments as the billed quantity (a small under-bill for the failed-segment gap);
  (2) the provider seam (`AsrStage`/`ConfigResolver`) is untouched; (3) the
  incremental path NEVER hard-blocks mid-recording (no `hold!` in the segment
  path); (4) the whole-file fallback guarantees completeness on any segment
  failure; (5) no segment is ever transcribed twice — the async job and the
  commit-time inline pass both go through the SAME atomic claim, and commit WAITS
  on an in-flight (`transcribing`) segment instead of re-invoking ASR.
- **Segment boundaries can cut words** (seam errors). The SDK plan mitigates by
  cutting on silence; a better ASR model is a pure config swap via
  `ModelAssignment`/`ConfigResolver` — nothing here is hardcoded to Whisper.
- **Feature flag**: `SCRIBE_INCREMENTAL_ASR` is OFF by default. To roll out,
  set the ENV var (or replace `Scribe::Incremental.enabled?` with an
  account/system setting lookup — the call sites in the controller and
  orchestrator go through that single predicate). When OFF, the system behaves
  exactly as before this plan.
- **Underspecified choices made here (smallest reasonable)**: (a) the flag is an
  ENV predicate in `Scribe::Incremental` rather than an account column — swap the
  predicate body when a per-account toggle is wanted; (b) the segment ceiling
  reuses `MAX_AUDIO_BYTES`; (c) `perform_now` is used for the inline
  trailing-segment finish at commit (synchronous and deterministic under both the
  `:inline` test adapter and solid_queue in prod).
- **Interaction with plan 020** (whole-file ASR optimization): the flag-OFF /
  no-segments branch of `ensure_transcript!` is the same whole-file path 020
  optimizes; keep them consistent. **Interaction with plan 021** (serializer
  transcript field): this plan sources that field; if 021 lands separately,
  reconcile to a single `transcript` key.
