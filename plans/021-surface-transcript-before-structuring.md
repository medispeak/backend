# Plan 021: Surface the transcript the instant ASR completes, decoupled from form/note structuring

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, add a new row for plan 021 to
> `plans/README.md` (the table currently ends at 019, so 021 is not yet listed):
> `| 021 | Surface the transcript the instant ASR lands | P2 | S-M | — | TODO |` —
> unless a reviewer dispatched you and told you they maintain the index.
>
> **Drift check (run first)**:
> `git diff --stat 58fd6a5..HEAD -- app/services/scribe/orchestrator.rb app/serializers/scribe_session_serializer.rb test/services/scribe/orchestrator_test.rb`
> If any in-scope file changed since this plan was written, compare the
> "Current state" excerpts against the live code before proceeding; on a
> mismatch, treat it as a STOP condition.

## Status

- **Priority**: P2
- **Effort**: M
- **Risk**: MED
- **Depends on**: none (soft-shares `ScribeSessionSerializer` with plan 022)
- **Category**: perf
- **Planned at**: commit `58fd6a5`, 2026-07-11

## Why this matters

ASR finishes and the `Transcript` row is persisted **early** in the pipeline
(`Orchestrator#ensure_transcript!`), but the clinician does not see the
transcript until much later. Two causes: (a) the orchestrator processes
`scribe_outputs` in creation order, and the frontend creates the form output
**before** the transcript output, so the `"transcript"` output's `result` is not
set to `:success` until **after** the slow structuring LLM call for the form
finishes; (b) clients read the transcript from the transcript **output's**
`result.text` (see the SDK's `extractTranscript`), which is gated on that same
ordering. Net: "stop recording → see transcript" waits on form structuring it
should not wait on. This plan makes the transcript visible as soon as ASR lands,
by (1) processing transcript-type outputs first and (2) exposing a stable
top-level `transcript` on the serialized session so clients no longer depend on
output ordering to read it. Session terminal semantics are unchanged.

## Current state

- `app/services/scribe/orchestrator.rb:35-54` — `#call` runs ASR once, then loops
  `scribe_outputs` **in the relation's default (creation) order**, so a form
  output created before the transcript output is structured first:
  ```ruby
  def call
    transcript = ensure_transcript!
    return @session if transcript.nil? && asr_failed?

    @session.scribe_outputs.each do |output|
      # Idempotent re-commit: an already-successful output is not reprocessed
      # or re-metered, so retrying a failed/partial session only reruns the
      # outputs that still need it. ScribeOutput's status enum is PREFIXED.
      next if output.status_success?

      stage = process_output(output, transcript)
      # Metering is best-effort and runs OUTSIDE the per-output rescue so a
      # metering failure can never demote a finalized output to :failure or
      # change the session rollup. A persisted success stays a success.
      meter_output(output, stage) if stage
    end

    finalize_session_status!
    @session
  end
  ```

- `app/services/scribe/orchestrator.rb:147-151` — the transcript output is a pure
  echo of the already-persisted transcript; it makes **no** LLM call and returns
  `nil` (nothing to meter). This is the cheap step that is currently blocked
  behind structuring:
  ```ruby
  def process_transcript_output(output, transcript)
    output.result = { text: transcript.text, language: transcript.language }
    output.status = :success
    output.save!
  end
  ```

- `app/services/scribe/orchestrator.rb:128-145` — `#process_output` dispatches on
  `output.output_type` (`"transcript"` / `"form"` / `"note"`) with a per-output
  `rescue StandardError` so one output's failure never aborts a sibling. Any
  reordering MUST preserve this isolation:
  ```ruby
  def process_output(output, transcript)
    case output.output_type
    when "transcript"
      process_transcript_output(output, transcript)
      nil
    when "form"
      process_form_output(output, transcript)
    when "note"
      process_note_output(output, transcript)
    else
      raise "unknown output_type=#{output.output_type.inspect}"
    end
  rescue StandardError => e
    output.result_errors = Array(output.result_errors) + [{ message: e.message }]
    output.status = :failure
    output.save!
    nil
  end
  ```

- `app/serializers/scribe_session_serializer.rb:1-31` — the serializer is a plain
  Ruby object returning a plain **Hash** from `#as_json`; there is **no**
  top-level transcript field today, so clients must dig it out of the outputs:
  ```ruby
  class ScribeSessionSerializer
    def initialize(session)
      @session = session
    end

    def as_json(*)
      {
        id: @session.id,
        status: @session.status,
        mode: @session.mode,
        language: @session.language,
        expires_at: @session.expires_at,
        outputs: @session.scribe_outputs.map { |output| serialize_output(output) }
      }
    end

    private

    def serialize_output(output)
      {
        id: output.id,
        type: output.output_type,
        status: output.status,
        result: output.result,
        errors: output.result_errors
      }
    end
  end
  ```

- `app/models/scribe_session.rb:25` — the session `has_one :transcript`, so
  `session.transcript` is the single canonical row (nil until ASR persists it):
  ```ruby
  has_one :transcript, dependent: :destroy
  ```

- `app/models/transcript.rb:1-3` — the `Transcript` model; it exposes `text` and
  `language` columns (both written by `Orchestrator#persist_transcript!` at
  `orchestrator.rb:99-108`):
  ```ruby
  class Transcript < ApplicationRecord
    belongs_to :scribe_session
  end
  ```

- `app/controllers/api/v2/scribe_sessions_controller.rb:407-409` — the controller
  serializes via this one helper for `show`/`index`/`commit`, so extending the
  serializer is the single home for the new field:
  ```ruby
  def serialize(session)
    ScribeSessionSerializer.new(session).as_json
  end
  ```

- `app/controllers/api/v2/scribe_sessions_controller.rb:398-405` — `status_for`
  drives the HTTP status and is **not** in scope; the session stays "processing"
  (`:accepted`) until all outputs finish. Only the transcript's *availability*
  moves earlier, never terminal semantics:
  ```ruby
  # 200 when terminal (completed/failed), 206 when partial, 202 otherwise.
  def status_for(session)
    case session.status
    when "completed", "failed" then :ok
    when "partial" then :partial_content
    else :accepted
    end
  end
  ```

- **EXTERNAL / cross-repo context — NOT in this backend repo.** The following two
  items live in the **`scribe-ts-sdk` repository** (the TypeScript client SDK, a
  separate repo), not here. They are provided as consumer context only; do not
  look for `scribe-ts-sdk/src/mapping.ts` in this repo, and the backwards-compat
  claim below must be **confirmed in the SDK repo**, not assumed from this plan:
  - `extractTranscript` (in the SDK's `src/mapping.ts`) reads the transcript from
    the transcript **output's** `result.text` (falling back to any output with a
    `text`). This is what today's ordering delays, and it is expected to keep
    working after this change because the new top-level field is **additive** —
    but that expectation should be verified against the SDK's actual code:
    ```ts
    export function extractTranscript(
      outputs: ScribeOutputResult[],
    ): string | undefined {
      const transcript = outputs.find((o) => o.type === "transcript");
      if (transcript && hasTextResult(transcript.result)) {
        return transcript.result.text;
      }
      const anyWithText = outputs.find((o) => hasTextResult(o.result));
      return anyWithText && hasTextResult(anyWithText.result)
        ? anyWithText.result.text
        : undefined;
    }
    ```
  - `mapSessionBody` (in the same SDK `src/mapping.ts`) reads only `body.id`,
    `body.status`, and `body.outputs`; an unknown top-level key like `transcript`
    is expected to be ignored, which would confirm the additive field cannot break
    the SDK — again, confirm in the SDK repo before relying on it.

- **Test pattern**: `test/services/scribe/orchestrator_test.rb:148-180` already
  proves per-output isolation — a form output truncates to `:failure` while the
  transcript output stays `:success` and the session rolls up to `"partial"`.
  Model the new independence assertion on this test:
  ```ruby
  test "form output fails on truncation while transcript output still succeeds => partial session" do
    stub_asr(text: "the patient has a fever")
    # finish_reason length means the structuring model truncated -> BadResponse
    # in StructuringStage, isolated per-output.
    stub_chat({ "diagnosis" => "fever" }, finish: "length")
    ...
    transcript_output = create(:scribe_output, scribe_session: session, output_type: "transcript")
    form_output = create(:scribe_output, scribe_session: session, output_type: "form", page: page)

    Scribe::Orchestrator.new(session).call
    ...
    transcript_output.reload
    assert transcript_output.status_success?

    form_output.reload
    assert form_output.status_failure?
    ...
    assert_equal "partial", session.reload.status
  end
  ```
  Also note the ASR/chat stub helpers (`stub_asr`, `stub_chat`, `attach_audio`,
  `build_page_with_fields`) at `orchestrator_test.rb:8-45`, and that a transcript
  can be created directly with `Transcript.create!(scribe_session:, text:,
  language:, provider:, model:)` (see `orchestrator_test.rb:264-265`).

## Commands you will need

| Purpose            | Command                                                                              | Expected on success |
|--------------------|--------------------------------------------------------------------------------------|---------------------|
| Orchestrator tests | `ASDF_RUBY_VERSION=3.4.1 bin/rails test test/services/scribe/orchestrator_test.rb`   | all pass            |
| Serializer test    | `ASDF_RUBY_VERSION=3.4.1 bin/rails test test/serializers/scribe_session_serializer_test.rb` | all pass     |
| Full tests         | `ASDF_RUBY_VERSION=3.4.1 bin/rails test`                                              | 0 failures          |
| Lint               | `ASDF_RUBY_VERSION=3.4.1 bin/rubocop`                                                 | no offenses         |

(The repo runs on Ruby 3.4.1 — see `.tool-versions`. The test env uses the
`:inline` ActiveJob adapter, so jobs run synchronously; you can call
`Scribe::Orchestrator.new(session).call` directly in tests as the existing suite
does.)

## Scope

**In scope** (the only files you should modify):
- `app/services/scribe/orchestrator.rb` — **ordering only** in `#call`.
- `app/serializers/scribe_session_serializer.rb` — add the top-level
  `transcript` field.
- `test/services/scribe/orchestrator_test.rb` — add the independence test.
- `test/serializers/scribe_session_serializer_test.rb` (create) — add the
  top-level field assertions.

**Out of scope** (do NOT touch, even though they look related):
- Any per-output logic or the metering path in `orchestrator.rb`
  (`process_form_output`, `process_note_output`, `meter_output`, `meter`,
  `record_and_deduct`, `dedupe_key_for`). Change **only** the order outputs are
  iterated in `#call` — do not alter what each output does or how it is metered.
- `app/controllers/api/v2/scribe_sessions_controller.rb` — `status_for` and
  terminal/HTTP semantics stay exactly as they are.
- The SDK / frontend (`scribe-ts-sdk/*`) — they already consume partials; their
  during-recording behavior is plan 022 / a separate FE plan.
- The structuring stages (`app/services/scribe/structuring_stage.rb`, etc.).

## Git workflow

- Branch: `advisor/021-surface-transcript-before-structuring` (or the repo's
  branch-naming convention if one is evident from `git branch -a`).
- Commit per step or per logical unit; match the repo's message style (recent
  history uses short imperative subjects, e.g. `git log --oneline -5` shows
  "Harden the browser scribe trust boundary", "Scope CORS to /api/* for browser
  scribe clients").
- Do NOT push or open a PR unless the operator instructed it.

## Steps

### Step 1: Process transcript-type outputs first in `Orchestrator#call`

In `app/services/scribe/orchestrator.rb`, change **only the iteration order** in
`#call` (lines 35-54) so every `output.output_type == "transcript"` output is
handled immediately after `ensure_transcript!` returns and before any form/note
output. Preserve everything else verbatim: the early return on ASR failure, the
`next if output.status_success?` idempotent skip, the `process_output` + `meter_output`
pairing, and `finalize_session_status!`.

Target shape — partition the relation, then iterate transcripts first:
```ruby
def call
  transcript = ensure_transcript!
  return @session if transcript.nil? && asr_failed?

  # Transcript outputs are a pure echo of the already-persisted transcript
  # (no LLM call), so process them FIRST — the transcript reaches :success in
  # the same instant it persists, before the slow structuring outputs run.
  # Ordering is the only behavior that changes; per-output processing,
  # isolation, and metering are unchanged.
  transcript_outputs, other_outputs =
    @session.scribe_outputs.partition { |o| o.output_type == "transcript" }

  (transcript_outputs + other_outputs).each do |output|
    next if output.status_success?

    stage = process_output(output, transcript)
    meter_output(output, stage) if stage
  end

  finalize_session_status!
  @session
end
```
Notes:
- `partition` materializes the relation once and keeps each partition in the
  original relative order, so form/note outputs still run in their prior order
  relative to one another (only transcripts jump ahead). This keeps the
  `dedupe_key_for` per-output keys stable (they are keyed on
  `session.id:output.id:function`, not iteration index — see
  `orchestrator.rb:271-277`).
- Do not introduce a DB `order(...)`; partition the already-loaded collection so
  you do not change the query or how `finalize_session_status!` reads statuses.

**Verify**: `ASDF_RUBY_VERSION=3.4.1 bin/rails test test/services/scribe/orchestrator_test.rb`
→ all existing tests pass (in particular the reorder must not break "runs ASR
once, fills transcript + form outputs, records usage" or the metering/partial
tests).

### Step 2: Expose a stable top-level `transcript` on the serialized session

In `app/serializers/scribe_session_serializer.rb`, add a top-level `transcript`
key sourced from `@session.transcript` (the `has_one`), independent of the
outputs. When no transcript row exists yet, the value is `nil`. Keep the existing
per-output serialization unchanged (backwards compatible).

Target shape:
```ruby
def as_json(*)
  {
    id: @session.id,
    status: @session.status,
    mode: @session.mode,
    language: @session.language,
    expires_at: @session.expires_at,
    transcript: serialize_transcript,
    outputs: @session.scribe_outputs.map { |output| serialize_output(output) }
  }
end

private

# Top-level transcript, sourced from the session's has_one :transcript so
# clients read it without depending on output ordering (plan 021). Additive:
# the per-output "transcript" output is still serialized unchanged, so the
# SDK's extractTranscript keeps working. Plan 022 will populate this field
# with the live (pre-commit) transcript — keep the "transcript" key name and
# { text:, language: } shape stable.
def serialize_transcript
  transcript = @session.transcript
  return nil if transcript.nil?

  { text: transcript.text, language: transcript.language }
end
```

**Verify**: `ASDF_RUBY_VERSION=3.4.1 bin/rails test test/services/scribe/orchestrator_test.rb`
→ still all pass (serializer change must not affect orchestrator behavior); the
new serializer assertions are added in Step 4.

### Step 3: Preload `:transcript` in the index action (avoid an N+1) and keep terminal/HTTP semantics

**Amended after execution:** the new top-level `transcript` serializer field reads
`@session.transcript` (a `has_one`), which the `index` action does not preload —
firing one query per listed session and failing the existing N+1 guard test
(`test/integration/api/v2/scribe_sessions_test.rb`, "index does not run an extra
query per session"). The correct, minimal fix is to add `:transcript` to the
`index` preload:

```ruby
sessions = account_sessions
           .includes(:scribe_outputs, :transcript)   # was .includes(:scribe_outputs)
```

Make **no other** change to `app/controllers/api/v2/scribe_sessions_controller.rb`.
Confirm by inspection that `status_for` (lines ~398-405) and the session status
rollup in `Orchestrator#finalize_session_status!` (`orchestrator.rb:298-301`) and
its `rollup_status` helper (`orchestrator.rb:303-313`) are otherwise unchanged —
the session must still stay `"processing"` (`:accepted`) until all outputs finish.
Only transcript *availability* moves earlier.

**Verify**: `ASDF_RUBY_VERSION=3.4.1 bin/rails test test/integration/api/v2/scribe_sessions_test.rb`
→ the N+1 guard passes (query count does not grow with more sessions).

### Step 4: Add tests (ordering + independence + top-level field)

Add two orchestrator tests and one serializer test.

**4a-i — Orchestrator ordering (pins Step 1).** The independence test in 4a-ii
below is necessary but **not sufficient**: it passes even on unmodified code,
because per-output isolation already guarantees the transcript output succeeds
regardless of iteration order. So it does NOT exercise Step 1's reorder. Add a
**mocha ordering test** that actually pins the order: stub
`Scribe::StructuringStage.new` to return a double whose `#call` records, at the
instant the form's structuring runs, whether the transcript output row is
**already** `status_success?`. If Step 1's `partition` were reverted, the form
would structure first and the transcript would still be `status_pending` at that
moment, so this assertion would fail. (The repo already `require`s
`mocha/minitest` in this file — see `orchestrator_test.rb:2` and the mocha usage
in `audio_chunks_test.rb`.) Target shape:
```ruby
test "orchestrator processes the transcript output before it structures the form (ordering pinned)" do
  stub_asr(text: "the patient has a fever")

  account = create(:account)
  session = create(:scribe_session, account: account, language: "en")
  attach_audio(session)
  page = build_page_with_fields

  # FE ordering: the form output is created BEFORE the transcript output. If
  # Step 1's partition were reverted, the form would structure first and this
  # test would fail (transcript still status_pending when the form runs).
  form_output = create(:scribe_output, scribe_session: session, output_type: "form", page: page)
  transcript_output = create(:scribe_output, scribe_session: session, output_type: "transcript")

  # Stub StructuringStage.new -> a double whose #call records, at the moment the
  # form structuring runs, whether the transcript output is ALREADY succeeded.
  # This is the assertion that genuinely exercises Step 1's ordering change.
  transcript_done_when_form_structured = nil
  fake_stage = Object.new
  fake_stage.define_singleton_method(:call) do |_transcript_text|
    transcript_done_when_form_structured = transcript_output.reload.status_success?
    # Match StructuringStage::Result's members (structuring_stage.rb:10-13);
    # usage: nil is fine — meter_output's record_and_deduct is best-effort and
    # rescues, so it cannot fail this test.
    Scribe::StructuringStage::Result.new(
      structured: { "diagnosis" => "fever" }, usage: nil, model: "test",
      provider: "test", finish_reason: "stop", valid: true, errors: []
    )
  end
  Scribe::StructuringStage.stubs(:new).returns(fake_stage)

  Scribe::Orchestrator.new(session).call

  assert_equal true, transcript_done_when_form_structured,
    "transcript output must be status_success BEFORE the form's StructuringStage runs"
end
```

**4a-ii — Orchestrator independence.** In
`test/services/scribe/orchestrator_test.rb`, add a test modeled on
"form output fails on truncation while transcript output still succeeds =>
partial session" (`orchestrator_test.rb:148-180`) that forces a sibling form
output to fail (`stub_chat({ "diagnosis" => "fever" }, finish: "length")`) and
asserts the transcript output is `status_success?` regardless — proving the
transcript is produced independently of the structuring outcome. This complements
(does not replace) the ordering test above. Target shape:
```ruby
test "transcript output succeeds even when a sibling form output fails" do
  stub_asr(text: "the patient has a fever")
  stub_chat({ "diagnosis" => "fever" }, finish: "length") # truncation -> form fails

  account = create(:account)
  session = create(:scribe_session, account: account, language: "en")
  attach_audio(session)
  page = build_page_with_fields

  # Create the form output BEFORE the transcript output to reproduce the FE's
  # ordering; the orchestrator must still finish the transcript first/regardless.
  form_output = create(:scribe_output, scribe_session: session, output_type: "form", page: page)
  transcript_output = create(:scribe_output, scribe_session: session, output_type: "transcript")

  Scribe::Orchestrator.new(session).call

  transcript_output.reload
  assert transcript_output.status_success?
  assert_equal "the patient has a fever", transcript_output.result["text"]

  form_output.reload
  assert form_output.status_failure?

  assert_equal "partial", session.reload.status
end
```

**4b — Serializer top-level field.** Create
`test/serializers/scribe_session_serializer_test.rb`. Assert the top-level
`transcript` equals `session.transcript.text`/`language` when a `Transcript`
exists, and is `nil` when none exists. Target shape:
```ruby
require "test_helper"

class ScribeSessionSerializerTest < ActiveSupport::TestCase
  test "top-level transcript is nil when the session has no transcript" do
    session = create(:scribe_session)
    json = ScribeSessionSerializer.new(session).as_json
    assert_nil json[:transcript]
  end

  test "top-level transcript mirrors the session's transcript when present" do
    session = create(:scribe_session, language: "en")
    Transcript.create!(
      scribe_session: session, text: "the patient has a fever",
      language: "en", provider: "openai_compatible", model: "whisper-1"
    )
    json = ScribeSessionSerializer.new(session.reload).as_json
    assert_equal "the patient has a fever", json[:transcript][:text]
    assert_equal "en", json[:transcript][:language]
  end
end
```
(If the `:scribe_session` factory requires additional attributes, mirror how the
orchestrator test builds sessions at `orchestrator_test.rb:51-53`.)

**Verify**:
`ASDF_RUBY_VERSION=3.4.1 bin/rails test test/services/scribe/orchestrator_test.rb test/serializers/scribe_session_serializer_test.rb`
→ all pass, including the 4 new tests (2 orchestrator + 2 serializer).

## Test plan

- **New orchestrator ordering test** in
  `test/services/scribe/orchestrator_test.rb`: "orchestrator processes the
  transcript output before it structures the form (ordering pinned)" — stubs
  `Scribe::StructuringStage.new` (mocha) and asserts the transcript output is
  **already** `status_success?` at the instant the form's `#call` runs. This is
  the test that actually exercises Step 1's `partition` reorder; it fails if the
  reorder is reverted.
- **New orchestrator independence test** in
  `test/services/scribe/orchestrator_test.rb`: "transcript output succeeds even
  when a sibling form output fails" — form output created first and forced to
  truncate (`finish: "length"`); asserts the transcript output is
  `status_success?` with the expected text and the session rolls up to
  `"partial"`. Structural pattern: the existing test at
  `orchestrator_test.rb:148-180`. (Complements, does not replace, the ordering
  test — on its own it passes even on unmodified code.)
- **New serializer test file** `test/serializers/scribe_session_serializer_test.rb`
  (create): (1) `transcript` is `nil` with no `Transcript`; (2) `transcript`
  equals `{ text:, language: }` from `session.transcript` when one exists.
- Existing coverage that must still pass unchanged: every test in
  `orchestrator_test.rb` (ASR-once, metering, partial, idempotent re-run,
  inline-fields, note, ASR-failure).
- Verification: `ASDF_RUBY_VERSION=3.4.1 bin/rails test` → 0 failures.

## Done criteria

Machine-checkable. ALL must hold:

- [ ] `Orchestrator#call` processes `output_type == "transcript"` outputs before any form/note output (`grep -n "partition" app/services/scribe/orchestrator.rb` returns a match inside `#call`)
- [ ] `ScribeSessionSerializer#as_json` returns a top-level `transcript` key (`grep -n "transcript:" app/serializers/scribe_session_serializer.rb` returns a match)
- [ ] The new orchestrator ordering test "orchestrator processes the transcript output before it structures the form (ordering pinned)" exists and passes (it stubs `Scribe::StructuringStage.new` and asserts the transcript output is already `status_success?` when the form structures — this is the guard that pins Step 1's reorder; the `partition` grep above is the structural backstop)
- [ ] The new orchestrator independence test "transcript output succeeds even when a sibling form output fails" exists and passes
- [ ] `test/serializers/scribe_session_serializer_test.rb` exists with both cases and passes
- [ ] `app/controllers/api/v2/scribe_sessions_controller.rb` `index` action preloads `:transcript` (`grep -n "includes(:scribe_outputs, :transcript)" app/controllers/api/v2/scribe_sessions_controller.rb` returns a match); no other controller change
- [ ] `ASDF_RUBY_VERSION=3.4.1 bin/rails test` exits 0 with 0 failures
- [ ] `ASDF_RUBY_VERSION=3.4.1 bin/rubocop` reports no offenses
- [ ] No files outside the in-scope list are modified (`git status`)
- [ ] `plans/README.md` has a new row for plan 021 added (the table currently ends at 019)

## STOP conditions

Stop and report back (do not improvise) if:

- The code at the cited locations in "Current state" does not match the excerpts
  (`orchestrator.rb:35-54` / `:147-151`, `scribe_session_serializer.rb:1-31`,
  `scribe_session.rb:25`) — the codebase has drifted since this plan was written.
- `ScribeSessionSerializer#as_json` is **not** a plain Hash you can extend (e.g.
  it has been rewritten to a different serialization mechanism) — report its
  actual shape rather than forcing the field in.
- Reordering the outputs makes any existing orchestrator test fail — especially a
  metering test — in a way that implicates `dedupe_key` or metering ordering;
  report the failing test and its output rather than altering the metering path
  (which is out of scope).
- A session has no transcript-type output at all: confirm the top-level
  `transcript` field still comes from `session.transcript` (the `has_one`), not
  from an output. If that path does not work, report it.
- A step's verification fails twice after a reasonable fix attempt.

## Maintenance notes

For the human/agent who owns this after the change lands:

- **Plan 022** will make the top-level `transcript` field reflect the *growing
  live* transcript before commit. Keep the field **name** (`transcript`) and its
  `{ text:, language: }` **shape** stable so 022 can populate it without a new
  wire contract.
- A reviewer should confirm two things: (1) `#call` genuinely processes
  transcript outputs first (partition ordering) while leaving per-output
  processing, isolation, and metering untouched; (2) the additive top-level field
  does **not** break the SDK's `extractTranscript` — the per-output `"transcript"`
  serialization at `serialize_output` is unchanged, and `mapSessionBody` (in the
  external `scribe-ts-sdk` repo's `src/mapping.ts`, not this repo) ignores unknown
  top-level keys. Confirm the additive-key behavior in the SDK repo, not from this
  plan.
- Deferred out of this plan: making the *frontend/SDK* prefer the new top-level
  field over `extractTranscript` — that is FE/plan-022 work, intentionally not
  done here to keep this change backwards compatible.
- Small choice made where underspecified: the top-level field serializes only
  `{ text:, language: }` (the two columns clients need to render the transcript),
  not the full `Transcript` row (provider/model/duration), to keep the wire
  surface minimal and stable for plan 022.
