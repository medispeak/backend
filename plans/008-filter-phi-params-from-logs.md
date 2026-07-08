# Plan 008: Filter PHI-bearing request params from the logs

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan
> in `plans/README.md` — unless a reviewer dispatched you and told you they
> maintain the index.
>
> **Drift check (run first)**:
> `git diff --stat 84da325..HEAD -- config/initializers/filter_parameter_logging.rb`
> If any in-scope file changed since this plan was written, compare the
> "Current state" excerpts against the live code before proceeding; on a
> mismatch, treat it as a STOP condition.

## Status

- **Priority**: P1
- **Effort**: S
- **Risk**: LOW
- **Depends on**: none
- **Category**: security
- **Planned at**: commit `84da325`, 2026-07-08

## Why this matters

Finding F8: this is a medical-scribe app subject to PHI handling, but the Rails
parameter filter does not redact the params that actually carry clinical text.
The v2 Scribe API permits a `context` param and the v1 transcriptions API permits
`context` (free-text clinical context), and completion/transcription flows move
`transcript`, `note`, `form`, `audio`, `results`, and `payload` data. When Rails
logs request parameters, these land in plaintext in the application/request logs
— a PHI leak into a lower-trust store (log aggregation, disk, backups). Adding
them to `filter_parameters` redacts them as `[FILTERED]` at the logging boundary
with zero behavioral change.

## Current state

- `config/initializers/filter_parameter_logging.rb:6-8` — the current list lacks
  every PHI-bearing key:
  ```ruby
  Rails.application.config.filter_parameters += [
    :passw, :email, :secret, :token, :_key, :crypt, :salt, :certificate, :otp, :ssn, :cvv, :cvc
  ]
  ```

- The PHI-bearing params exist here:
  - `app/controllers/api/v2/scribe_sessions_controller.rb:169-174` permits
    `context` (nested under `outputs`):
    ```ruby
    def create_params
      params.permit(
        :language_hint, :mode, :callback_url,
        outputs: [ :type, :page_id, :template_ref, { context: {} } ]
      )
    end
    ```
  - `app/controllers/api/v1/transcriptions_controller.rb:76-78` permits
    `context` (and moves `audio_file` / `transcription_text`):
    ```ruby
    def transcription_params
      params.require(:transcription).permit(:audio_file, :duration, :context)
    end
    ```

- `filter_parameters` matching is **partial** (substring): `:passw` already
  matches `password`. So `:context` matches `context`, `:audio` matches
  `audio_file`, etc. — one entry covers its variants.

## Commands you will need

| Purpose    | Command                                                                                   | Expected on success |
|------------|-------------------------------------------------------------------------------------------|---------------------|
| New test   | `ASDF_RUBY_VERSION=3.2.2 bin/rails test test/initializers/filter_parameter_logging_test.rb`| all pass            |
| Full tests | `ASDF_RUBY_VERSION=3.2.2 bin/rails test`                                                   | 0 failures          |
| Lint       | `ASDF_RUBY_VERSION=3.2.2 bin/rubocop`                                                      | no offenses         |

## Scope

**In scope** (the only files you should modify):
- `config/initializers/filter_parameter_logging.rb`
- `test/initializers/filter_parameter_logging_test.rb` (create)

**Out of scope** (do NOT touch, even though they look related):
- Any controller `permit` list — this plan changes ONLY logging redaction, not
  what params are accepted.
- `config/environments/*` log configuration.

## Git workflow

- Branch: `advisor/008-filter-phi-params-from-logs`
- One commit; short imperative subject (e.g. `Filter PHI params from logs`).
- Do NOT push or open a PR unless the operator instructed it.

## Steps

### Step 1: Add the PHI-bearing keys to `filter_parameters`

In `config/initializers/filter_parameter_logging.rb`, append the PHI keys to the
existing array (keep the current entries):
```ruby
Rails.application.config.filter_parameters += [
  :passw, :email, :secret, :token, :_key, :crypt, :salt, :certificate, :otp, :ssn, :cvv, :cvc,
  :context, :transcript, :transcription_text, :payload, :results, :note, :form, :audio, :audio_file
]
```

**Verify**: `grep -n "context" config/initializers/filter_parameter_logging.rb`
→ one match on the new line.

### Step 2: Add a test asserting the params are redacted

Create `test/initializers/filter_parameter_logging_test.rb` (plain
`ActiveSupport::TestCase`; no special harness needed):
```ruby
require "test_helper"

class FilterParameterLoggingTest < ActiveSupport::TestCase
  PHI_KEYS = %i[context transcript transcription_text payload results note form audio audio_file].freeze

  test "PHI-bearing params are registered as filter_parameters" do
    filters = Rails.application.config.filter_parameters
    PHI_KEYS.each do |key|
      assert_includes filters, key, "#{key} must be filtered from logs"
    end
  end

  test "a context value is redacted by the parameter filter" do
    filter = ActiveSupport::ParameterFilter.new(Rails.application.config.filter_parameters)
    filtered = filter.filter("context" => "patient reports chest pain")

    assert_equal "[FILTERED]", filtered["context"]
  end

  test "a nested transcript value is redacted by the parameter filter" do
    filter = ActiveSupport::ParameterFilter.new(Rails.application.config.filter_parameters)
    filtered = filter.filter("outputs" => [{ "transcript" => "full clinical note" }])

    assert_equal "[FILTERED]", filtered["outputs"].first["transcript"]
  end
end
```

**Verify**:
`ASDF_RUBY_VERSION=3.2.2 bin/rails test test/initializers/filter_parameter_logging_test.rb`
→ all 3 tests pass.

## Test plan

- New file `test/initializers/filter_parameter_logging_test.rb`:
  - asserts each PHI key is present in `Rails.application.config.filter_parameters`.
  - asserts `ActiveSupport::ParameterFilter` redacts a top-level `context` value
    to `[FILTERED]` (the exact regression: clinical text no longer logged).
  - asserts redaction reaches a nested `transcript` inside `outputs` (matches the
    real v2 param shape).
- Structural pattern: a straightforward `ActiveSupport::TestCase` (like
  `test/models/*_test.rb`); no fixtures or HTTP needed.
- Verification: `ASDF_RUBY_VERSION=3.2.2 bin/rails test` → 0 failures.

## Done criteria

Machine-checkable. ALL must hold:

- [ ] `grep -n ":context, :transcript" config/initializers/filter_parameter_logging.rb` returns one match
- [ ] `ASDF_RUBY_VERSION=3.2.2 bin/rails test test/initializers/filter_parameter_logging_test.rb` passes (3 tests)
- [ ] `ASDF_RUBY_VERSION=3.2.2 bin/rails test` exits 0 with 0 failures
- [ ] `ASDF_RUBY_VERSION=3.2.2 bin/rubocop` reports no offenses
- [ ] No files outside the in-scope list are modified (`git status`)
- [ ] `plans/README.md` status row updated

## STOP conditions

Stop and report back (do not improvise) if:

- `config/initializers/filter_parameter_logging.rb` no longer matches the
  "Current state" excerpt (drift) — e.g. the list was already extended.
- The redaction test does not produce `[FILTERED]` (a non-default
  `filter_parameters_mask` or a custom filter proc is configured somewhere) —
  report the actual mask rather than editing the test to match.

## Maintenance notes

For the human/agent who owns this after the change lands:

- **Partial-match over-filtering is intentional but noteworthy**: because
  matching is substring-based, `:form` also redacts any param whose name contains
  "form" (e.g. `information`, `format`, `platform_id`), `:note` redacts
  `footnote`/`denote`, and `:audio` redacts `audio_file`. For PHI this
  err-on-the-side-of-more-redaction behavior is acceptable (logging-only, no
  behavior change), but a reviewer should be aware that some non-PHI debug params
  will now also show `[FILTERED]`. If that becomes a debugging pain, switch the
  offending entry to a more specific `Regexp` or an exact-key filter proc.
- New PHI-carrying params added to any controller `permit` list in future must be
  added here too — there is no automatic coupling.
- A reviewer should confirm no test asserts on the *unredacted* value of any of
  these keys in a logged context.
