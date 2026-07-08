# Plan 015: Treat truncated/malformed OpenAI-compatible 200s as transient (enable fallback)

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan
> in `plans/README.md` — unless a reviewer dispatched you and told you they
> maintain the index.
>
> **Drift check (run first)**:
> `git diff --stat 84da325..HEAD -- app/services/llm/adapters/openai_compatible.rb app/services/llm/caller.rb app/services/scribe/structuring_stage.rb test/services/llm/openai_compatible_adapter_test.rb`
> If any in-scope file changed since this plan was written, compare the
> "Current state" excerpts against the live code before proceeding; on a
> mismatch, treat it as a STOP condition.

## Status

- **Priority**: P2
- **Effort**: S
- **Risk**: LOW
- **Depends on**: none
- **Category**: bug
- **Planned at**: commit `84da325`, 2026-07-08

## Why this matters

When an OpenAI-compatible provider returns HTTP 200 but the message content is
truncated or malformed JSON, `JSON.parse` raises `JSON::ParserError` inside the
adapter. That exception is NOT in `Llm::Caller::TRANSIENT`, so it escapes the
fallback machinery entirely — the request just blows up instead of retrying the
fallback provider. The Anthropic adapter already handles the analogous case
correctly (it raises `Llm::BadResponse` for a missing/incomplete tool block, so
`Caller` falls back). This plan makes the OpenAI-compatible adapter consistent:
a truncated/garbled 200 becomes a transient `Llm::BadResponse` and triggers
fallback, instead of a hard crash.

## Current state

- `app/services/llm/adapters/openai_compatible.rb:37-57` — `structure` parses
  the content inside the method and only rescues `Faraday::Error`:
  ```ruby
  def structure(messages:, schema:, **_opts)
    started = monotonic
    params = { model: config.api_model_id, messages: messages }
    params[:response_format] = json_schema_format(schema) if config.capability?(:supports_json_schema)

    response = client.chat(parameters: params)
    choice = response.dig("choices", 0) || {}
    content = choice.dig("message", "content")

    Llm::Result.new(
      structured: content && JSON.parse(content),   # <- raises JSON::ParserError on garbled content
      model: config.api_model_id,
      provider: config.provider_kind.to_s,
      usage: usage_from(response["usage"]),
      finish_reason: choice["finish_reason"],
      latency_ms: elapsed_ms(started),
      raw: response
    )
  rescue Faraday::Error => e                          # <- does NOT catch JSON::ParserError
    raise map_transport_error(e)
  end
  ```

- `app/services/llm/caller.rb:9` — the transient set that drives one fallback
  attempt. `JSON::ParserError` is deliberately absent:
  ```ruby
  TRANSIENT = [Llm::Timeout, Llm::RateLimited, Llm::BadResponse].freeze
  ```
  and `run` (`:23-29`) rescues `*TRANSIENT` then retries `@config.fallback`.

- `app/services/scribe/structuring_stage.rb:64-68` — the `finish_reason` guard
  runs only AFTER the adapter returns a `Result`, so it cannot help when the
  adapter itself raised during parse:
  ```ruby
  def guard_completion!(llm)
    return if llm.finish_reason.nil? || COMPLETE.include?(llm.finish_reason.to_s)
    raise Llm::BadResponse, "model did not complete (finish_reason=#{llm.finish_reason})"
  end
  ```
  (`COMPLETE = %w[stop end_turn]` at `:22`.)

- Contrast — the Anthropic adapter already raises `Llm::BadResponse` for an
  incomplete/missing tool block (`app/services/llm/adapters/anthropic.rb:82-96`):
  ```ruby
  unless block
    raise Llm::BadResponse, "Anthropic response missing #{TOOL_NAME} tool_use block"
  end
  ```
  and its doc at `:80-81` notes "A 2xx response without the expected block is a
  bad response (e.g. truncation or refusal), which triggers fallback upstream."

- `Llm::BadResponse < Llm::Error` (`app/services/llm/bad_response.rb:3`); it is a
  transient error.

- The adapter tests live at **`test/services/llm/openai_compatible_adapter_test.rb`**
  (NOT under `test/services/llm/adapters/` — only the Anthropic test is under
  `adapters/`). Existing relevant patterns in that file:
  - `chat_body(content:, finish:)` helper builds a 200 body (`:32-35`).
  - `test_500_maps_to_bad_response` (`:89-97`) — shape for asserting a
    `Llm::BadResponse` is raised.
  - `test_caller_falls_back_on_rate_limit` (`:99-111`) — shape for asserting
    `Caller` falls back to a second stubbed endpoint.

## Commands you will need

| Purpose        | Command                                                                        | Expected on success |
|----------------|--------------------------------------------------------------------------------|---------------------|
| Adapter test   | `ASDF_RUBY_VERSION=3.2.2 bin/rails test test/services/llm/openai_compatible_adapter_test.rb` | all pass  |
| Full tests     | `ASDF_RUBY_VERSION=3.2.2 bin/rails test`                                        | 0 failures          |
| Lint           | `ASDF_RUBY_VERSION=3.2.2 bin/rubocop app/services/llm/adapters/openai_compatible.rb` | no offenses    |

Standalone (no Rails boot) is also supported for this file:
`ruby -Itest test/services/llm/openai_compatible_adapter_test.rb` — the header
manually requires the LLM files (`:8-12`).

## Scope

**In scope** (the only files you should modify):
- `app/services/llm/adapters/openai_compatible.rb`
- `test/services/llm/openai_compatible_adapter_test.rb`

**Out of scope** (do NOT touch, even though they look related):
- `app/services/llm/caller.rb` — do NOT add `JSON::ParserError` to `TRANSIENT`.
  The adapter, not the caller, owns mapping provider quirks to the `Llm::Error`
  hierarchy (see `Adapter#map_transport_error`); keep that boundary.
- `app/services/scribe/structuring_stage.rb` — its `finish_reason` guard already
  handles the returned-Result case; this plan fixes the raised-during-parse case
  in the adapter.
- `app/services/llm/adapters/anthropic.rb` — already correct; it is the exemplar.

## Steps

### Step 1: Guard `finish_reason` and wrap the JSON parse in the adapter

In `OpenaiCompatible#structure`, (a) treat a non-complete `finish_reason` as a
bad response before trusting the content, and (b) map a `JSON::ParserError` from
`JSON.parse(content)` to `Llm::BadResponse`. Both make truncation transient and
consistent with the Anthropic adapter.

Target shape:
```ruby
def structure(messages:, schema:, **_opts)
  started = monotonic
  params = { model: config.api_model_id, messages: messages }
  params[:response_format] = json_schema_format(schema) if config.capability?(:supports_json_schema)

  response = client.chat(parameters: params)
  choice = response.dig("choices", 0) || {}
  finish_reason = choice["finish_reason"]
  content = choice.dig("message", "content")

  # A 200 that stopped early (e.g. "length") carries truncated content; don't
  # trust it. Surface as a transient BadResponse so Caller falls back — mirrors
  # the Anthropic adapter's missing-tool-block handling.
  if finish_reason && !%w[stop].include?(finish_reason.to_s)
    raise Llm::BadResponse, "model did not complete (finish_reason=#{finish_reason})"
  end

  Llm::Result.new(
    structured: content && parse_json(content),
    model: config.api_model_id,
    provider: config.provider_kind.to_s,
    usage: usage_from(response["usage"]),
    finish_reason: finish_reason,
    latency_ms: elapsed_ms(started),
    raw: response
  )
rescue Faraday::Error => e
  raise map_transport_error(e)
end

private

def parse_json(content)
  JSON.parse(content)
rescue JSON::ParserError => e
  raise Llm::BadResponse, "provider returned unparseable JSON content: #{e.message}"
end
```

Notes:
- OpenAI-compatible completion `finish_reason` values include `stop` (normal),
  `length` (truncated), `content_filter`, and `tool_calls`. This plan treats only
  `stop` as complete for the structuring path; if the operator relies on
  `tool_calls`-style responses here, STOP and report (this adapter uses
  `response_format`/`content`, not tool calls, so `stop` is expected).
- Do NOT remove the existing `rescue Faraday::Error` mapping.
- `StructuringStage#guard_completion!` will still run on the returned Result for
  the non-raising cases — that is fine and complementary; do not remove it.

**Verify**: `ASDF_RUBY_VERSION=3.2.2 bin/rails test test/services/llm/openai_compatible_adapter_test.rb`
→ existing tests still pass (`chat_body` uses `finish: "stop"`, so the happy path
is unaffected).

### Step 2: Add adapter + caller regression tests

Add two tests to `test/services/llm/openai_compatible_adapter_test.rb`:

1. A garbled/truncated 200 maps to `Llm::BadResponse` (model after
   `test_500_maps_to_bad_response`):
   ```ruby
   def test_truncated_content_maps_to_bad_response
     truncated = { choices: [{ message: { content: '{"name":' }, finish_reason: "length" }],
                   usage: { prompt_tokens: 5, completion_tokens: 1 } }.to_json
     stub_request(:post, "https://api.openai.com/v1/chat/completions")
       .to_return(status: 200, headers: { "Content-Type" => "application/json" }, body: truncated)

     assert_raises(Llm::BadResponse) do
       adapter.structure(messages: [{ role: "user", content: "hi" }], schema: core_schema)
     end
   end

   def test_unparseable_json_with_stop_maps_to_bad_response
     garbled = { choices: [{ message: { content: "not json at all" }, finish_reason: "stop" }],
                 usage: { prompt_tokens: 5, completion_tokens: 1 } }.to_json
     stub_request(:post, "https://api.openai.com/v1/chat/completions")
       .to_return(status: 200, headers: { "Content-Type" => "application/json" }, body: garbled)

     assert_raises(Llm::BadResponse) do
       adapter.structure(messages: [{ role: "user", content: "hi" }], schema: core_schema)
     end
   end
   ```

2. `Caller` falls back to the secondary provider on the truncated primary (model
   after `test_caller_falls_back_on_rate_limit`):
   ```ruby
   def test_caller_falls_back_on_truncated_primary
     truncated = { choices: [{ message: { content: '{"name":' }, finish_reason: "length" }] }.to_json
     stub_request(:post, "https://primary.test/v1/chat/completions")
       .to_return(status: 200, body: truncated, headers: { "Content-Type" => "application/json" })
     stub_request(:post, "https://fallback.test/v1/chat/completions")
       .to_return(status: 200, body: chat_body(content: { "name" => "Fallback" }), headers: { "Content-Type" => "application/json" })

     fb = config(base_url: "https://fallback.test/")
     primary = config(base_url: "https://primary.test/", fallback: fb)

     result = Llm::Caller.structure(primary, messages: [{ role: "user", content: "hi" }], schema: core_schema)
     assert_equal({ "name" => "Fallback" }, result.structured)
     assert_requested(:post, "https://fallback.test/v1/chat/completions", times: 1)
   end
   ```

**Verify**: `ASDF_RUBY_VERSION=3.2.2 bin/rails test test/services/llm/openai_compatible_adapter_test.rb`
→ all pass, including the 3 new tests.

## Test plan

- New tests in `test/services/llm/openai_compatible_adapter_test.rb`:
  - truncated 200 (`finish_reason: "length"`, partial JSON) → `Llm::BadResponse`.
  - `finish_reason: "stop"` but unparseable body → `Llm::BadResponse`.
  - `Caller` falls back to the secondary provider when the primary returns a
    truncated 200 (the end-to-end behavior this plan restores).
- Structural patterns to follow (same file): `test_500_maps_to_bad_response`
  (`:89-97`) and `test_caller_falls_back_on_rate_limit` (`:99-111`).
- Verification: `ASDF_RUBY_VERSION=3.2.2 bin/rails test test/services/llm/openai_compatible_adapter_test.rb`
  → all pass; full suite `ASDF_RUBY_VERSION=3.2.2 bin/rails test` → 0 failures.

## Done criteria

Machine-checkable. ALL must hold:

- [ ] A truncated 200 (`finish_reason: "length"`) raises `Llm::BadResponse` (new test passes)
- [ ] A 200 with unparseable content raises `Llm::BadResponse` (new test passes)
- [ ] `Caller.structure` falls back to the secondary provider on a truncated primary (new test passes)
- [ ] `JSON::ParserError` is NOT added to `Llm::Caller::TRANSIENT` (`grep -n "JSON::ParserError" app/services/llm/caller.rb` returns no match)
- [ ] Existing adapter tests (happy path, 429, 500, existing fallback) still pass
- [ ] `ASDF_RUBY_VERSION=3.2.2 bin/rails test` exits 0 with 0 failures
- [ ] `ASDF_RUBY_VERSION=3.2.2 bin/rubocop app/services/llm/adapters/openai_compatible.rb` reports no offenses
- [ ] No files outside the in-scope list are modified (`git status`)
- [ ] `plans/README.md` status row updated

## STOP conditions

Stop and report back (do not improvise) if:

- The code at `openai_compatible.rb:37-57` does not match "Current state" (drift).
- The structuring path here actually depends on `finish_reason: "tool_calls"` (or
  another non-`stop` value) as a *success* signal — the Step 1 guard would then
  wrongly reject valid responses; report before changing the completeness set.
- Any existing adapter/caller test starts failing for a reason other than the new
  behavior (e.g. `chat_body`'s default `finish: "stop"` no longer passes) — that
  signals the guard is too strict.

## Maintenance notes

For the human/agent who owns this after the change lands:

- The completeness signal is duplicated: the adapter now checks `finish_reason`
  and `StructuringStage#guard_completion!` also checks it on the returned Result.
  That redundancy is intentional (adapter catches parse-time truncation; the
  stage catches returned-but-incomplete). If you unify them later, keep both
  failure modes covered.
- A reviewer should confirm the adapter still only rescues transport errors from
  Faraday and that the JSON wrapping does not swallow non-parse exceptions.
- The `stop`-only completeness list mirrors `StructuringStage::COMPLETE`'s intent
  for OpenAI-style responses; if a provider uses a different "normal" terminal
  reason, extend the allowlist deliberately, not reactively.
