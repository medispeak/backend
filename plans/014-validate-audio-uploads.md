# Plan 014: Validate audio uploads (content-type + size) before processing

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan
> in `plans/README.md` — unless a reviewer dispatched you and told you they
> maintain the index.
>
> **Drift check (run first)**:
> `git diff --stat 84da325..HEAD -- app/controllers/api/v2/scribe_sessions_controller.rb app/models/scribe_session.rb app/controllers/api/v1/transcriptions_controller.rb app/models/transcription.rb Gemfile Gemfile.lock`
> If any in-scope file changed since this plan was written, compare the
> "Current state" excerpts against the live code before proceeding; on a
> mismatch, treat it as a STOP condition.

## Status

- **Priority**: P2
- **Effort**: S
- **Risk**: LOW
- **Depends on**: none
- **Category**: security
- **Planned at**: commit `84da325`, 2026-07-08

## Why this matters

Both the v2 scribe API and the v1 transcription API accept arbitrary uploads and
attach them as "audio" with no content-type or size validation. A client can
attach a huge file or a non-audio payload (e.g. an executable or a giant zip),
which is then persisted to storage and handed to a paid ASR provider. That is a
denial-of-wallet / resource-exhaustion vector and a storage-abuse risk. This plan
enforces an audio content-type allowlist and a max byte size, rejecting bad
uploads with the API's standard error envelope **before** the file is processed
or a job is enqueued.

## Current state

- `app/controllers/api/v2/scribe_sessions_controller.rb:29-43` — the v2 audio
  action attaches whatever arrives with zero validation:
  ```ruby
  # POST /api/v2/scribe_sessions/:id/audio
  def audio
    session = find_session
    return unless session
    if session.expired?
      render_error(code: "session_expired", message: "Scribe session has expired", status: :gone)
      return
    end
    session.audio_files.attach(params[:audio])   # <- no type/size check
    session.update!(status: "uploading")
    render json: { id: session.id, status: session.status }, status: :ok
  end
  ```

- `app/models/scribe_session.rb:9` — the attachment, with no validation:
  ```ruby
  has_many_attached :audio_files
  ```

- `app/controllers/api/v1/transcriptions_controller.rb:59-66` — the v1 path
  attaches `params[:transcription][:audio_file]` via strong params and forwards
  it to ASR:
  ```ruby
  def create_transcription(page)
    transcription = page.transcriptions.create!(transcription_params.merge(user: current_user))
    text = ai_transcribe(params[:transcription][:audio_file], page: page, account: current_user.account)
    ...
  end
  ```
  `transcription_params` (`:76-78`) permits `:audio_file`, and
  `app/models/transcription.rb:6` declares `has_one_attached :audio_file` with no
  validation.

- The v2 API renders errors through a shared envelope
  (`app/controllers/api/v2/base_controller.rb:36-45`):
  ```ruby
  def render_error(code:, message:, status:, details: {})
    render json: { error: { code:, message:, request_id:, details: } }, status:
  end
  ```
  Existing v2 error codes in use include `validation_error` and
  `session_expired`.

- The v1 API raises `GenericException.new(message:, code:)` for errors (see
  `transcriptions_controller.rb:8-9` and `:70-73` `handle_audio_upload_error`,
  which uses `code: :failed_dependency`).

- **No** `active_storage_validations` gem is present
  (`grep -i active_storage_validations Gemfile.lock` → not found).

- The v2 integration test already uploads a real `audio/mpeg` tempfile via
  `Rack::Test::UploadedFile.new(file.path, "audio/mpeg")`
  (`test/integration/api/v2/scribe_sessions_test.rb:161-167`) — reuse that
  helper's pattern for the happy path and vary it for the rejection cases.

## Commands you will need

| Purpose        | Command                                                                             | Expected on success |
|----------------|-------------------------------------------------------------------------------------|---------------------|
| Bundle install | `ASDF_RUBY_VERSION=3.2.2 bundle install`                                             | exit 0              |
| v2 test        | `ASDF_RUBY_VERSION=3.2.2 bin/rails test test/integration/api/v2/scribe_sessions_test.rb` | all pass       |
| Full tests     | `ASDF_RUBY_VERSION=3.2.2 bin/rails test`                                             | 0 failures          |
| Lint           | `ASDF_RUBY_VERSION=3.2.2 bin/rubocop`                                                | no offenses         |

## Scope

**In scope** (the only files you should modify):
- `Gemfile` and `Gemfile.lock` (only if you choose the gem approach in Step 1)
- `app/models/scribe_session.rb`
- `app/models/transcription.rb`
- `app/controllers/api/v2/scribe_sessions_controller.rb`
- `app/controllers/api/v1/transcriptions_controller.rb`
- `test/integration/api/v2/scribe_sessions_test.rb`

**Out of scope** (do NOT touch, even though they look related):
- The ASR/structuring pipeline (`app/services/scribe/*`, `app/services/llm/*`) —
  validation must reject before that runs; do not change the pipeline.
- The idempotency / quota logic in the controllers.
- The v1 `format_transcription` / response shape — v1 clients depend on it.

## Steps

### Step 1: Choose an enforcement mechanism

Two viable approaches — pick ONE and apply it consistently to both attachments.

- **Approach 1 (gem):** add `active_storage_validations` to the `:default`
  group in `Gemfile`, `bundle install`, then declare validations on each
  attachment. Cleaner and declarative.
- **Approach 2 (manual, no new dependency):** validate in the controller before
  attaching — check `params[:audio].content_type` against an allowlist and
  `params[:audio].size` against a max. Simpler blast radius, no gem.

Define the constants once (reuse in both spots):
```ruby
ALLOWED_AUDIO_TYPES = %w[audio/mpeg audio/mp4 audio/wav audio/x-wav audio/webm audio/ogg audio/m4a audio/aac].freeze
MAX_AUDIO_BYTES = 25.megabytes
```
(Tune the allowlist/size to match what the ASR provider accepts — 25 MB mirrors
common Whisper limits. If the operator specifies different limits, use theirs.)

**Verify (Approach 1 only):** `ASDF_RUBY_VERSION=3.2.2 bundle install` → exit 0;
`grep active_storage_validations Gemfile.lock` → present.

### Step 2: Reject bad uploads in the v2 audio action

In `app/controllers/api/v2/scribe_sessions_controller.rb#audio`, before
`session.audio_files.attach(...)`, validate and reject with the standard
envelope. Target shape (Approach 2 style):
```ruby
upload = params[:audio]

if upload.blank?
  render_error(code: "validation_error", message: "audio file is required", status: :unprocessable_entity)
  return
end
unless ALLOWED_AUDIO_TYPES.include?(upload.content_type)
  render_error(code: "validation_error", message: "unsupported audio content type: #{upload.content_type}", status: :unprocessable_entity)
  return
end
if upload.size > MAX_AUDIO_BYTES
  render_error(code: "audio_upload_failed", message: "audio exceeds #{MAX_AUDIO_BYTES} bytes", status: :unprocessable_entity)
  return
end

session.audio_files.attach(upload)
session.update!(status: "uploading")
```
(With Approach 1, instead declare on the model and rescue the
`ActiveRecord::RecordInvalid` from a `save!`/attach to render the same envelope —
but the controller must still return `validation_error`/`audio_upload_failed`
codes, not a 500.)

**Verify**: `ASDF_RUBY_VERSION=3.2.2 bin/rails test test/integration/api/v2/scribe_sessions_test.rb`
→ the existing lifecycle test (valid `audio/mpeg`) still passes.

### Step 3: Enforce on the v1 transcription upload

Mirror the guard for `params[:transcription][:audio_file]` in
`app/controllers/api/v1/transcriptions_controller.rb#create` (or on the
`Transcription#audio_file` attachment if using Approach 1). On rejection, raise
the v1 error contract:
```ruby
raise GenericException.new(message: "unsupported or oversized audio upload", code: :unprocessable_entity)
```
Reject **before** `page.transcriptions.create!` / `ai_transcribe` runs so no row
is persisted and no provider call is made for a bad upload.

**Verify**: `ASDF_RUBY_VERSION=3.2.2 bin/rails test test/integration/api/v1/transcriptions_golden_test.rb`
→ still passes (the golden contract for valid input is unchanged).

### Step 4: Declare model-level validation as defense in depth (if Approach 1)

If you took Approach 1, add to `app/models/scribe_session.rb`:
```ruby
validates :audio_files,
  content_type: ALLOWED_AUDIO_TYPES,
  size: { less_than_or_equal_to: MAX_AUDIO_BYTES }
```
and the `has_one_attached` equivalent on `app/models/transcription.rb`. Keep the
controller's explicit envelope-rendering so clients get the right code, not a
generic 422.

**Verify**: `ASDF_RUBY_VERSION=3.2.2 bin/rails test` → 0 failures.

## Test plan

- New tests in `test/integration/api/v2/scribe_sessions_test.rb` (model after the
  existing `audio_upload` helper at `:161-167` and the lifecycle test):
  - "audio upload rejects a non-audio content type" — build an
    `Rack::Test::UploadedFile` with `"application/zip"` (or `"text/plain"`),
    POST to `/api/v2/scribe_sessions/:id/audio`, assert `422` and
    `error.code == "validation_error"`, and assert NO attachment was persisted
    (`session.reload.audio_files.attached?` is false).
  - "audio upload rejects an oversized file" — build an uploaded file larger than
    `MAX_AUDIO_BYTES` with a valid audio content-type, POST, assert `422` and
    `error.code == "audio_upload_failed"`.
- Structural pattern: reuse the `audio_upload` private helper's approach; add a
  variant that takes `content_type`/byte-size arguments.
- Verification: `ASDF_RUBY_VERSION=3.2.2 bin/rails test test/integration/api/v2/scribe_sessions_test.rb`
  → all pass, including the 2 new tests.

## Done criteria

Machine-checkable. ALL must hold:

- [ ] A non-audio v2 upload returns `422` with `error.code` in `{validation_error, audio_upload_failed}` and does not attach the file
- [ ] An oversized v2 upload returns `422` with `error.code == "audio_upload_failed"`
- [ ] The v1 transcription create rejects non-audio/oversized uploads before persisting a Transcription or calling ASR
- [ ] The existing v2 lifecycle test and v1 golden test still pass
- [ ] Approach 1 only: `grep active_storage_validations Gemfile.lock` returns a match
- [ ] `ASDF_RUBY_VERSION=3.2.2 bin/rails test` exits 0 with 0 failures
- [ ] `ASDF_RUBY_VERSION=3.2.2 bin/rubocop` reports no offenses
- [ ] No files outside the in-scope list are modified (`git status`)
- [ ] `plans/README.md` status row updated

## STOP conditions

Stop and report back (do not improvise) if:

- The code at the cited controller/model lines does not match "Current state"
  (drift).
- `params[:audio]` (v2) or `params[:transcription][:audio_file]` (v1) is not a
  `Rack`/`ActionDispatch` uploaded file responding to `content_type`/`size` at
  the point you validate (e.g. it arrives as a signed blob id) — the guard shape
  would differ; report what the param actually is.
- You cannot determine an appropriate max size / allowlist for the ASR provider
  in use — surface the question rather than guessing wildly (the 25 MB default is
  a placeholder).
- Adding `active_storage_validations` fails to install on the current Ruby.

## Maintenance notes

For the human/agent who owns this after the change lands:

- Keep `ALLOWED_AUDIO_TYPES` / `MAX_AUDIO_BYTES` aligned with the actual ASR
  provider limits; if a new provider with different limits is added via config,
  these should move to configuration rather than hard-coded constants.
- A reviewer should confirm rejection happens **before** attachment/persistence
  and job enqueue (not just a model validation that fires after a partial write),
  and that both v1 and v2 paths are covered.
- Content-type from the client is spoofable; this is a first-line guard. If
  stronger assurance is needed later, add server-side magic-byte sniffing — noted
  and deferred here.
