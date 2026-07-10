# Embeddable Scribe SDK — Backend (Phase 1) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add the four browser-facing backend capabilities that let a browser SDK drive a Medispeak scribe session without an account secret: inline form schema, scoped session tokens, native chunked/resumable upload, and scoped CORS.

**Architecture:** Extend the existing async v2 API (`app/controllers/api/v2/`). Inline fields reuse the `Scribe::SchemaBuilder` duck-typed seam (like `NoteField`). Session tokens are stateless `MessageVerifier`-signed blobs verified in `Api::V2::BaseController`. Chunks are rows with an ActiveStorage attachment each, reassembled into the session's canonical `audio_files` blob at commit, after which the existing `Orchestrator` runs unchanged.

**Tech Stack:** Rails 8.0 / Ruby 3.4.1 / PostgreSQL, ActiveStorage, Minitest + factory_bot + webmock + mocha.

## Global Constraints

- Commands run bare (the repo pins Ruby via `.tool-versions` = `3.4.1`): `bin/rails test`, `bin/rails db:migrate`, `bin/rails db:test:prepare`, `bin/rubocop`. If a bare command resolves the wrong Ruby, prefix `ASDF_RUBY_VERSION=3.4.1`.
- Full-suite baseline before this plan: **234 runs, 0 failures** on a good seed. Two integration tests (`admin/ai_config_test.rb`, `templates_builder_test.rb`) are a KNOWN pre-existing Devise/Warden flake (seed-dependent) — if the only failures are those two with "Could not find a valid mapping for User", re-run with another seed; do not chase them.
- The 5 field types are exactly `string, number, boolean, single_select, multi_select`. No new types.
- Money/metering isolation, job non-re-raise, `PriceBook`-returns-zero, unlimited-when-no-`AccountCredit` are by-design — do not touch.
- Never weaken existing hardening: keep the plan-014 audio allowlist/size validation, plan-006 callback SSRF validation, plan-002 quota gate, plan-004 commit idempotency intact.
- Commit atomically per task; message style matches the repo log (short imperative); end each with `Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>`. Do NOT push.

---

## File Structure

**Task 1 — Inline form schema**
- Create `db/migrate/<ts>_add_inline_fields_to_scribe_outputs.rb` — `inline_fields` jsonb on `scribe_outputs`.
- Create `app/services/scribe/inline_field.rb` — duck-typed field built from the API payload + payload validation.
- Modify `app/services/scribe/orchestrator.rb` — `process_form_output` uses inline fields when present.
- Modify `app/controllers/api/v2/scribe_sessions_controller.rb` — `create_params`, `validate_outputs`, `build_outputs`.
- Test `test/services/scribe/inline_field_test.rb`, extend `test/services/scribe/orchestrator_test.rb`, `test/integration/api/v2/scribe_sessions_test.rb`.

**Task 2 — Scoped session tokens**
- Create `app/services/scribe/session_token.rb` — mint/verify.
- Modify `app/controllers/api/v2/base_controller.rb` — dual auth (account token OR session token).
- Modify `app/controllers/api/v2/scribe_sessions_controller.rb` — `tokens` action, `find_session` dual-path, `require_account_token!`.
- Modify `config/routes.rb` — `post :tokens` member route.
- Test `test/services/scribe/session_token_test.rb`, `test/integration/api/v2/session_tokens_test.rb`.

**Task 3 — Native chunked + resumable upload**
- Create `db/migrate/<ts>_create_scribe_audio_chunks.rb`.
- Create `app/models/scribe_audio_chunk.rb`.
- Create `app/services/scribe/chunk_assembler.rb`.
- Modify `app/models/scribe_session.rb` — `has_many :audio_chunks`.
- Modify `app/controllers/api/v2/scribe_sessions_controller.rb` — `audio_chunks`, `audio_status`, commit reassembly + no-audio guard.
- Modify `config/routes.rb` — `post "audio/chunks"`, `get "audio/status"`.
- Test `test/models/scribe_audio_chunk_test.rb`, `test/services/scribe/chunk_assembler_test.rb`, `test/integration/api/v2/audio_chunks_test.rb`.

**Task 4 — Browser CORS**
- Modify `config/initializers/cors.rb` — scope to `/api/*`.
- Test `test/integration/api/v2/cors_test.rb`.

Execution order: **1 → 2 → 3 → 4** (Tasks 1–3 all touch `scribe_sessions_controller.rb`; commit atomically between them; Task 4 is independent).

---

## Task 1: Inline form schema

**Files:** Create `app/services/scribe/inline_field.rb`, migration; Modify `app/services/scribe/orchestrator.rb`, `app/controllers/api/v2/scribe_sessions_controller.rb`; Test as above.

**Interfaces:**
- Produces: `Scribe::InlineField.build_all(fields_array) -> [InlineField]` (duck-typed on `title, friendly_name, description, field_type, enum_options, minimum, maximum`); `Scribe::InlineField.validation_error(fields_array) -> String | nil`. `ScribeOutput#inline_fields` jsonb.

- [ ] **Step 1: Migration + model column**

```ruby
# db/migrate/<ts>_add_inline_fields_to_scribe_outputs.rb
class AddInlineFieldsToScribeOutputs < ActiveRecord::Migration[8.0]
  def change
    add_column :scribe_outputs, :inline_fields, :jsonb
  end
end
```
Run: `bin/rails db:migrate` → exit 0; `bin/rails db:test:prepare`.

- [ ] **Step 2: Failing test for `InlineField`**

```ruby
# test/services/scribe/inline_field_test.rb
require "test_helper"
class Scribe::InlineFieldTest < ActiveSupport::TestCase
  test "from_payload maps key->title and label->friendly_name" do
    f = Scribe::InlineField.from_payload({ "key" => "hr", "label" => "Heart Rate", "type" => "number" })
    assert_equal "hr", f.title
    assert_equal "Heart Rate", f.friendly_name
    assert_equal "number", f.field_type
  end

  test "build_all feeds SchemaBuilder to a key-keyed, correct schema" do
    fields = Scribe::InlineField.build_all([
      { "key" => "hr", "label" => "Heart Rate", "type" => "number" },
      { "key" => "sx", "label" => "Symptoms", "type" => "multi_select", "enum" => %w[fever cough] }
    ])
    schema = Scribe::SchemaBuilder.new(fields: fields).call
    assert_equal "number", schema[:properties]["hr"][:type]
    assert_equal "array", schema[:properties]["sx"][:type]
    assert_equal %w[fever cough], schema[:properties]["sx"][:items][:enum]
  end

  test "validation_error flags bad payloads" do
    assert_nil Scribe::InlineField.validation_error([{ "key" => "a", "type" => "string" }])
    assert_match(/non-empty/, Scribe::InlineField.validation_error([]))
    assert_match(/key/, Scribe::InlineField.validation_error([{ "type" => "string" }]))
    assert_match(/duplicate/, Scribe::InlineField.validation_error([{ "key" => "a", "type" => "string" }, { "key" => "a", "type" => "string" }]))
    assert_match(/invalid field type/, Scribe::InlineField.validation_error([{ "key" => "a", "type" => "date" }]))
    assert_match(/enum/, Scribe::InlineField.validation_error([{ "key" => "a", "type" => "single_select" }]))
  end
end
```
Run: `bin/rails test test/services/scribe/inline_field_test.rb` → FAIL (uninitialized constant).

- [ ] **Step 3: Implement `InlineField`**

```ruby
# app/services/scribe/inline_field.rb
module Scribe
  # Duck-typed field for an ad-hoc (inline) form output — the same seam
  # SchemaBuilder consumes for FormField / NoteField. `title` is the RESULT key
  # (SchemaBuilder keys properties by #title); `friendly_name` is the human label.
  InlineField = Struct.new(
    :title, :friendly_name, :description, :field_type,
    :enum_options, :minimum, :maximum, keyword_init: true
  ) do
    TYPES = %w[string number boolean single_select multi_select].freeze
    SELECT_TYPES = %w[single_select multi_select].freeze

    def self.from_payload(hash)
      h = hash.to_h.with_indifferent_access
      new(
        title: h[:key], friendly_name: h[:label].presence || h[:key],
        description: h[:description], field_type: h[:type],
        enum_options: h[:enum], minimum: h[:minimum], maximum: h[:maximum]
      )
    end

    def self.build_all(fields)
      Array(fields).map { |f| from_payload(f) }
    end

    def self.validation_error(fields)
      return "fields must be a non-empty array" unless fields.is_a?(Array) && fields.any?
      seen = []
      fields.each do |f|
        h = f.to_h.with_indifferent_access
        key = h[:key]
        return "each field needs a key" if key.blank?
        return "duplicate field key: #{key}" if seen.include?(key)
        seen << key
        return "invalid field type: #{h[:type].inspect}" unless TYPES.include?(h[:type].to_s)
        if SELECT_TYPES.include?(h[:type].to_s) && Array(h[:enum]).empty?
          return "#{h[:type]} field #{key} requires enum options"
        end
      end
      nil
    end
  end
end
```
Run: `bin/rails test test/services/scribe/inline_field_test.rb` → PASS.

- [ ] **Step 4: Orchestrator uses inline fields — failing test**

Add to `test/services/scribe/orchestrator_test.rb` (follow the existing form-output test; stub `Scribe::StructuringStage` as those tests do). Assert: a `scribe_output` with `inline_fields` set and no `page` structures successfully and its `result` is stored. Run it → FAIL.

- [ ] **Step 5: Implement in `orchestrator.rb`**

In `process_form_output` (and `process_note_output` where it reads `output.page`), branch on inline fields:

```ruby
def process_form_output(output, transcript)
  if output.inline_fields.present?
    fields = Scribe::InlineField.build_all(output.inline_fields)
    system_prompt = nil
  else
    fields = output.page.form_fields.to_a
    system_prompt = output.page.prompt
  end

  config = Llm::ConfigResolver.call(function: :structuring, page: output.page, account: session.account)
  stage = Scribe::StructuringStage.new(
    config: config, fields: fields, context: output.context, system_prompt: system_prompt
  ).call(transcript.text)

  output.result = stage.structured
  if stage.valid
    output.status = :success
  else
    output.status = :partial
    output.result_errors = stage.errors
  end
  output.save!
  stage
end
```
`Llm::ConfigResolver.call(page: nil, ...)` already falls back to account/system. Run the orchestrator test → PASS.

- [ ] **Step 6: Controller accepts `fields` xor `page_id` — failing integration test**

Add to `test/integration/api/v2/scribe_sessions_test.rb`: create a session with `outputs: [{ type: "form", fields: [{ key: "hr", label: "Heart Rate", type: "number" }] }]` → `201`; and a negative: a form output with neither `page_id` nor `fields` → `422 validation_error`; and both → `422`. Run → FAIL.

- [ ] **Step 7: Implement controller changes**

`create_params` — permit inline fields:
```ruby
def create_params
  params.permit(
    :language_hint, :mode, :callback_url,
    outputs: [
      :type, :page_id, :template_ref, { context: {} },
      { fields: [ :key, :label, :type, :description, :minimum, :maximum, { enum: [] } ] }
    ]
  )
end
```

`validate_outputs` — for a `form` output, require exactly one of `page_id` / `fields`:
```ruby
if type == "form"
  page_id = output[:page_id]
  fields  = output[:fields]
  has_page = page_id.present?
  has_fields = fields.present?
  return "form output needs exactly one of page_id or fields" if has_page == has_fields
  if has_page
    return "page_id #{page_id.inspect} does not reference an existing page" unless Page.exists?(id: page_id)
  else
    err = Scribe::InlineField.validation_error(fields.map { |f| f.to_h })
    return err if err
  end
end
```

`build_outputs` — store inline fields:
```ruby
session.scribe_outputs.create!(
  status: "pending",
  output_type: output[:type],
  page_id: output[:page_id],
  template_ref: output[:template_ref],
  context: output[:context].presence || {},
  inline_fields: output[:fields].present? ? output[:fields].map { |f| f.to_h } : nil
)
```
Run: `bin/rails test test/integration/api/v2/scribe_sessions_test.rb` → PASS.

- [ ] **Step 8: Full suite + commit**

Run: `bin/rails test` → green (mind the known flake); `bin/rubocop` on changed files → no new offenses.
```bash
git add -A && git commit -m "Add inline form schema to v2 scribe outputs"
```

---

## Task 2: Scoped session tokens

**Files:** Create `app/services/scribe/session_token.rb`; Modify `app/controllers/api/v2/base_controller.rb`, `app/controllers/api/v2/scribe_sessions_controller.rb`, `config/routes.rb`; Test as above.

**Interfaces:**
- Produces: `Scribe::SessionToken.mint(session, ttl:) -> [token_string, expires_at]`; `Scribe::SessionToken.verify(raw) -> { "sid" => Integer, "scope" => [..] } | nil`. `BaseController#current_session_claims`, `#require_account_token!`.

- [ ] **Step 1: Failing test for `SessionToken`**

```ruby
# test/services/scribe/session_token_test.rb
require "test_helper"
class Scribe::SessionTokenTest < ActiveSupport::TestCase
  setup { @session = create(:scribe_session, expires_at: 1.hour.from_now) }

  test "mint then verify round-trips sid and scope" do
    token, exp = Scribe::SessionToken.mint(@session)
    assert token.start_with?("mss_")
    assert exp <= @session.expires_at
    claims = Scribe::SessionToken.verify(token)
    assert_equal @session.id, claims["sid"]
    assert_equal %w[audio read], claims["scope"]
  end

  test "verify rejects tampered, foreign-prefix, and expired tokens" do
    token, = Scribe::SessionToken.mint(@session)
    assert_nil Scribe::SessionToken.verify(token + "x")
    assert_nil Scribe::SessionToken.verify("msk_live_whatever")
    expired, = Scribe::SessionToken.mint(@session, ttl: -1.second)
    assert_nil Scribe::SessionToken.verify(expired)
  end
end
```
Run → FAIL.

- [ ] **Step 2: Implement `SessionToken`**

```ruby
# app/services/scribe/session_token.rb
module Scribe
  # Stateless, signed, short-lived token scoping a browser client to ONE scribe
  # session's upload+read routes. No DB row: verification is a signature check;
  # revocation rides on the short TTL and the session's own expiry/status.
  module SessionToken
    PREFIX = "mss_"
    SCOPE = %w[audio read].freeze
    DEFAULT_TTL = 15.minutes

    module_function

    def mint(session, ttl: DEFAULT_TTL)
      exp = [ ttl.from_now, session.expires_at ].compact.min
      token = PREFIX + verifier.generate({ "sid" => session.id, "scope" => SCOPE }, expires_at: exp)
      [ token, exp ]
    end

    def verify(raw)
      return nil unless raw.to_s.start_with?(PREFIX)
      verifier.verify(raw.delete_prefix(PREFIX))
    rescue ActiveSupport::MessageVerifier::InvalidSignature
      nil # covers tampering AND expiry (ExpiredMessage < InvalidSignature)
    end

    def verifier
      Rails.application.message_verifier(:scribe_session)
    end
  end
end
```
Run → PASS.

- [ ] **Step 3: Route + failing integration test**

`config/routes.rb`, in the `scribe_sessions` member block add `post :tokens`. Then `test/integration/api/v2/session_tokens_test.rb`: (a) `POST /:id/tokens` with the account bearer → `201` `{token, expires_at}`; (b) minting for another account's session → `404`; (c) minting with a session token (not account) → `401`. Run → FAIL.

- [ ] **Step 4: Dual auth in `base_controller.rb`**

Replace the single-token auth with account-OR-session resolution:
```ruby
before_action :authenticate!

def authenticate!
  return if current_api_token || current_session_claims
  head :unauthorized
end

def current_api_token
  return @current_api_token if defined?(@current_api_token)
  @current_api_token = ApiToken.authenticate(bearer_token)
end

def current_session_claims
  return @current_session_claims if defined?(@current_session_claims)
  @current_session_claims = Scribe::SessionToken.verify(bearer_token)
end

def current_account
  current_api_token&.account
end

# Account-only actions (create/index/tokens/config/usage) call this.
def require_account_token!
  head :unauthorized unless current_api_token
end
```
(Keep `bearer_token`, `render_error`, `with_idempotency` as-is.)

- [ ] **Step 5: Controller `tokens` action, dual-path `find_session`, account-only guard**

```ruby
before_action :require_account_token!, only: [ :create, :index, :tokens ]

# POST /api/v2/scribe_sessions/:id/tokens  (account token only)
def tokens
  session = ScribeSession.where(account: current_account).find_by(id: params[:id])
  return render_error(code: "session_not_found", message: "Scribe session not found", status: :not_found) unless session
  token, exp = Scribe::SessionToken.mint(session)
  render json: { token: token, expires_at: exp.iso8601 }, status: :created
end
```
Refactor `find_session` so a session token can only reach its own session:
```ruby
def find_session
  session =
    if current_api_token
      ScribeSession.where(account: current_account).find_by(id: params[:id])
    elsif current_session_claims && current_session_claims["sid"].to_s == params[:id].to_s
      ScribeSession.find_by(id: current_session_claims["sid"])
    end
  unless session
    render_error(code: "session_not_found", message: "Scribe session not found", status: :not_found)
    return nil
  end
  session
end
```
Run: `bin/rails test test/integration/api/v2/session_tokens_test.rb` → PASS.

- [ ] **Step 6: Prove session-token scope — extend the integration test**

Add: a minted session token (a) reads `GET /:id` (200/202) and (b) is rejected `401` on `GET /api/v2/scribe_sessions` (index), `GET /api/v2/config`, and on `GET /:otherId`. Run → PASS.

- [ ] **Step 7: Full suite + commit**

Run: `bin/rails test` → green; `bin/rubocop` changed files clean.
```bash
git add -A && git commit -m "Add scoped session tokens for browser scribe clients"
```

---

## Task 3: Native chunked + resumable upload

**Files:** Create migration, `app/models/scribe_audio_chunk.rb`, `app/services/scribe/chunk_assembler.rb`; Modify `app/models/scribe_session.rb`, `app/controllers/api/v2/scribe_sessions_controller.rb`, `config/routes.rb`; Test as above.

**Interfaces:**
- Produces: `ScribeAudioChunk(scribe_session_id, seq, final, content_type)` + `has_one_attached :data`; `Scribe::ChunkAssembler.assemble!(session) -> Boolean` (attaches the reassembled blob to `session.audio_files`, returns false if no chunks).

- [ ] **Step 1: Migration + model**

```ruby
# db/migrate/<ts>_create_scribe_audio_chunks.rb
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
```ruby
# app/models/scribe_audio_chunk.rb
class ScribeAudioChunk < ApplicationRecord
  belongs_to :scribe_session
  has_one_attached :data

  validates :seq, presence: true,
            numericality: { only_integer: true, greater_than_or_equal_to: 0 },
            uniqueness: { scope: :scribe_session_id }
end
```
Add to `app/models/scribe_session.rb`: `has_many :audio_chunks, class_name: "ScribeAudioChunk", dependent: :destroy`.
Run `bin/rails db:migrate && bin/rails db:test:prepare`.

- [ ] **Step 2: Failing test for `ChunkAssembler`**

```ruby
# test/services/scribe/chunk_assembler_test.rb
require "test_helper"
class Scribe::ChunkAssemblerTest < ActiveSupport::TestCase
  test "assembles chunks in seq order into one audio blob" do
    session = create(:scribe_session)
    { 2 => "world", 0 => "hel", 1 => "lo " }.each do |seq, bytes|
      c = session.audio_chunks.create!(seq: seq, content_type: "audio/webm")
      c.data.attach(io: StringIO.new(bytes), filename: "c#{seq}", content_type: "audio/webm")
    end
    assert Scribe::ChunkAssembler.assemble!(session)
    assert session.audio_files.attached?
    assert_equal "hello world", session.audio_files.first.download
    assert_equal "audio/webm", session.audio_files.first.blob.content_type
  end

  test "returns false when there are no chunks" do
    assert_equal false, Scribe::ChunkAssembler.assemble!(create(:scribe_session))
  end
end
```
Run → FAIL.

- [ ] **Step 3: Implement `ChunkAssembler`**

```ruby
# app/services/scribe/chunk_assembler.rb
require "tempfile"
module Scribe
  # Concatenates a session's uploaded audio chunks (in seq order) into one blob
  # attached to session.audio_files, so the existing Orchestrator path runs
  # unchanged. Content-type comes from the lowest-seq chunk (defaulting to
  # audio/webm), which must be in ScribeSession::ALLOWED_AUDIO_TYPES.
  module ChunkAssembler
    module_function

    def assemble!(session)
      chunks = session.audio_chunks.order(:seq).to_a
      return false if chunks.empty?

      content_type = chunks.first.content_type.presence || "audio/webm"
      tmp = Tempfile.new([ "scribe_audio", ".bin" ]); tmp.binmode
      chunks.each { |c| tmp.write(c.data.download) }
      tmp.rewind
      session.audio_files.attach(io: tmp, filename: "consultation", content_type: content_type)
      tmp.close!
      true
    end
  end
end
```
Run → PASS.

- [ ] **Step 4: Chunk + status endpoints — failing integration test**

`config/routes.rb` member block: `post "audio/chunks", to: "scribe_sessions#audio_chunks"` and `get "audio/status", to: "scribe_sessions#audio_status"`. Then `test/integration/api/v2/audio_chunks_test.rb` (auth with a session token from Task 2): upload seqs 1,0 out of order + one re-POST of seq 0 (idempotent); `GET audio/status` → `received_seqs: [0,1]`; `POST commit` → session leaves `created/uploading` (inline job runs) and a `Transcript`/outputs exist; assert the reassembled audio equals the concatenation. Run → FAIL.

- [ ] **Step 5: Implement controller actions + commit reassembly**

```ruby
MAX_CHUNK_BYTES = 8.megabytes

# POST /:id/audio/chunks
def audio_chunks
  session = find_session
  return unless session
  return if reject_expired(session)

  seq = params.require(:seq).to_i
  upload = params.require(:chunk)
  if upload.respond_to?(:size) && upload.size > MAX_CHUNK_BYTES
    return render_error(code: "validation_error", message: "chunk too large", status: :unprocessable_entity)
  end

  chunk = session.audio_chunks.find_or_initialize_by(seq: seq)
  chunk.content_type = upload.content_type.presence || chunk.content_type || "audio/webm"
  chunk.final = true if ActiveModel::Type::Boolean.new.cast(params[:final])
  chunk.data.attach(upload)
  chunk.save!
  session.update!(status: "uploading") if session.created?
  render json: { received: seq }, status: :ok
end

# GET /:id/audio/status
def audio_status
  session = find_session
  return unless session
  chunks = session.audio_chunks.order(:seq).to_a
  render json: {
    received_seqs: chunks.map(&:seq),
    final_seen: chunks.any?(&:final),
    bytes: chunks.sum { |c| c.data.blob&.byte_size.to_i }
  }, status: :ok
end
```
Add a small `reject_expired(session)` helper mirroring the existing `session.expired?` → `410 session_expired` pattern already used in `audio`/`commit` (extract it if convenient). In `commit`, before enqueuing, reassemble chunks if the single-shot blob is absent, and reject when neither is present:
```ruby
# inside commit, after the expired? check, before the quota hold:
if session.audio_files.blank? && session.audio_chunks.exists?
  Scribe::ChunkAssembler.assemble!(session)
end
if session.audio_files.blank?
  return render_error(code: "audio_upload_failed", message: "No audio uploaded for this session", status: :unprocessable_entity)
end
```
Run: `bin/rails test test/integration/api/v2/audio_chunks_test.rb` → PASS.

- [ ] **Step 6: Golden equivalence + no-audio + full suite, commit**

Add a test asserting resume-then-commit produces the SAME persisted transcript as a single-shot `POST /:id/audio` of the concatenated bytes (stub ASR identically in both). Add: `commit` with no audio → `422 audio_upload_failed`. Run `bin/rails test` → green; `bin/rubocop` clean.
```bash
git add -A && git commit -m "Add native chunked and resumable audio upload"
```

---

## Task 4: Browser CORS

**Files:** Modify `config/initializers/cors.rb`; Test `test/integration/api/v2/cors_test.rb`.

- [ ] **Step 1: Failing test**

```ruby
# test/integration/api/v2/cors_test.rb
require "test_helper"
class Api::V2::CorsTest < ActionDispatch::IntegrationTest
  test "api routes send CORS headers for cross-origin requests" do
    get "/api/v2/config", headers: { "Origin" => "https://app.example.com", "Authorization" => "Bearer nope" }
    assert_equal "https://app.example.com", response.headers["Access-Control-Allow-Origin"]
  end

  test "non-api routes are not CORS-enabled" do
    get "/up", headers: { "Origin" => "https://app.example.com" }
    assert_nil response.headers["Access-Control-Allow-Origin"]
  end
end
```
Run → the second assertion FAILs today (wildcard covers `/up`).

- [ ] **Step 2: Scope the initializer**

```ruby
# config/initializers/cors.rb
Rails.application.config.middleware.insert_before 0, Rack::Cors do
  allow do
    origins "*"
    resource "/api/*",
             headers: :any,
             methods: [ :get, :post, :patch, :put, :options ],
             credentials: false
  end
end
```
Run: `bin/rails test test/integration/api/v2/cors_test.rb` → PASS.

- [ ] **Step 3: Full suite + commit**

Run `bin/rails test` → green.
```bash
git add -A && git commit -m "Scope CORS to /api/* for browser scribe clients"
```

---

## Self-Review

- **Spec coverage:** §5.1 tokens → Task 2. §5.2 chunked upload → Task 3. §5.3 inline schema → Task 1. §5.4 CORS → Task 4. §8 security (session-token scope, no account secret, scoped CORS) → Tasks 2 & 4 tests. §9 testing → each task's tests (token scope/expiry, chunk idempotency/resume/golden, inline `fields` xor `page_id`). SDK (§6) and FE (§10 phase 3) are out of Phase 1 by design.
- **Type consistency:** `InlineField` duck-types the 7 `SchemaBuilder` methods; `title=key` matches `SchemaBuilder`'s `h[f.title]` property keying. `SessionToken.mint -> [token, exp]`, `verify -> claims|nil` used consistently. `ChunkAssembler.assemble!(session) -> bool` used in commit + tests. Reassembly content-type ∈ `ScribeSession::ALLOWED_AUDIO_TYPES` (`audio/webm` is listed).
- **No placeholders:** every code step has real code; test steps have real assertions.
- **Cross-plan integrity:** commit still runs the plan-002 quota hold and plan-004 idempotency/status guard (reassembly is inserted before the hold, not replacing it); audio validation (plan 014) still applies to the reassembled blob.
