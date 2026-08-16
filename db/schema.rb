# This file is auto-generated from the current state of the database. Instead
# of editing this file, please use the migrations feature of Active Record to
# incrementally modify your database, and then regenerate this schema definition.
#
# This file is the source Rails uses to define your schema when running `bin/rails
# db:schema:load`. When creating a new database, `bin/rails db:schema:load` tends to
# be faster and is potentially less error prone than running all of your
# migrations from scratch. Old migrations may fail to apply correctly if those
# migrations use external dependencies or application code.
#
# It's strongly recommended that you check this file into your version control system.

ActiveRecord::Schema[8.1].define(version: 2026_08_17_093000) do
  # These are extensions that must be enabled in order to support this database
  enable_extension "pg_catalog.plpgsql"

  create_table "account_credits", force: :cascade do |t|
    t.bigint "account_id", null: false
    t.decimal "balance", precision: 16, scale: 6, default: "0.0", null: false
    t.datetime "created_at", null: false
    t.decimal "credit_limit", precision: 16, scale: 6
    t.string "refill_period"
    t.datetime "updated_at", null: false
    t.index ["account_id"], name: "index_account_credits_on_account_id", unique: true
  end

  create_table "accounts", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "default_callback_url"
    t.string "name", null: false
    t.bigint "parent_id"
    t.jsonb "settings", default: {}, null: false
    t.string "status", default: "active", null: false
    t.datetime "updated_at", null: false
    t.string "webhook_secret"
    t.index ["parent_id"], name: "index_accounts_on_parent_id"
    t.check_constraint "jsonb_typeof(settings) = 'object'::text", name: "accounts_settings_is_object"
  end

  create_table "active_storage_attachments", force: :cascade do |t|
    t.bigint "blob_id", null: false
    t.datetime "created_at", null: false
    t.string "name", null: false
    t.bigint "record_id", null: false
    t.string "record_type", null: false
    t.index ["blob_id"], name: "index_active_storage_attachments_on_blob_id"
    t.index ["record_type", "record_id", "name", "blob_id"], name: "index_active_storage_attachments_uniqueness", unique: true
  end

  create_table "active_storage_blobs", force: :cascade do |t|
    t.bigint "byte_size", null: false
    t.string "checksum"
    t.string "content_type"
    t.datetime "created_at", null: false
    t.string "filename", null: false
    t.string "key", null: false
    t.text "metadata"
    t.string "service_name", null: false
    t.index ["key"], name: "index_active_storage_blobs_on_key", unique: true
  end

  create_table "active_storage_variant_records", force: :cascade do |t|
    t.bigint "blob_id", null: false
    t.string "variation_digest", null: false
    t.index ["blob_id", "variation_digest"], name: "index_active_storage_variant_records_uniqueness", unique: true
  end

  create_table "ai_models", force: :cascade do |t|
    t.boolean "active", default: true, null: false
    t.bigint "ai_provider_id", null: false
    t.string "api_model_id", null: false
    t.jsonb "capabilities", default: {}, null: false
    t.datetime "created_at", null: false
    t.string "display_name"
    t.datetime "updated_at", null: false
    t.index ["ai_provider_id"], name: "index_ai_models_on_ai_provider_id"
    t.check_constraint "jsonb_typeof(capabilities) = 'object'::text", name: "ai_models_capabilities_is_object"
  end

  create_table "ai_providers", force: :cascade do |t|
    t.boolean "active", default: true, null: false
    t.text "api_key"
    t.string "base_url"
    t.datetime "created_at", null: false
    t.string "kind", null: false
    t.string "name", null: false
    t.string "organization_id"
    t.integer "request_timeout", default: 120, null: false
    t.datetime "updated_at", null: false
  end

  create_table "api_tokens", force: :cascade do |t|
    t.bigint "account_id"
    t.boolean "active", default: true, null: false
    t.datetime "created_at", null: false
    t.datetime "expires_at"
    t.datetime "last_used_at"
    t.string "name"
    t.string "scopes", default: [], array: true
    t.string "token_digest"
    t.string "token_prefix"
    t.datetime "updated_at", null: false
    t.bigint "user_id", null: false
    t.index ["account_id"], name: "index_api_tokens_on_account_id"
    t.index ["token_digest"], name: "index_api_tokens_on_token_digest", unique: true
    t.index ["user_id"], name: "index_api_tokens_on_user_id"
  end

  create_table "audio_model_prices", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "currency", default: "USD"
    t.datetime "deprecated_at"
    t.datetime "effective_at"
    t.string "model"
    t.decimal "price_per_minute", precision: 16, scale: 8
    t.string "provider"
    t.datetime "updated_at", null: false
    t.index ["provider", "model", "effective_at"], name: "idx_on_provider_model_effective_at_ef696c0068"
  end

  create_table "credit_transactions", force: :cascade do |t|
    t.bigint "account_id", null: false
    t.decimal "amount", precision: 16, scale: 6, null: false
    t.decimal "balance_after", precision: 16, scale: 6
    t.decimal "balance_before", precision: 16, scale: 6
    t.datetime "created_at", null: false
    t.bigint "scribe_session_id"
    t.string "txn_type", null: false
    t.datetime "updated_at", null: false
    t.bigint "usage_event_id"
    t.index ["account_id"], name: "index_credit_transactions_on_account_id"
    t.index ["usage_event_id", "txn_type"], name: "index_credit_transactions_on_usage_event_and_type", unique: true
  end

  create_table "document_model_prices", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "currency", default: "USD"
    t.datetime "deprecated_at"
    t.datetime "effective_at"
    t.string "model"
    t.decimal "price_per_page", precision: 16, scale: 8
    t.string "provider"
    t.datetime "updated_at", null: false
    t.index ["provider", "model", "effective_at"], name: "idx_on_provider_model_effective_at_96c85bf6e5"
  end

  create_table "domains", force: :cascade do |t|
    t.boolean "archived", default: false, null: false
    t.datetime "created_at", null: false
    t.string "fqdn", null: false
    t.bigint "template_id", null: false
    t.datetime "updated_at", null: false
    t.index ["template_id"], name: "index_domains_on_template_id"
  end

  create_table "form_fields", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "description"
    t.string "enum_options", default: [], array: true
    t.string "field_type", default: "string", null: false
    t.string "friendly_name", null: false
    t.string "maximum"
    t.jsonb "metadata", default: {}, null: false
    t.string "minimum"
    t.bigint "page_id", null: false
    t.string "title"
    t.datetime "updated_at", null: false
    t.index ["page_id"], name: "index_form_fields_on_page_id"
    t.check_constraint "jsonb_typeof(metadata) = 'object'::text", name: "form_fields_metadata_is_object"
  end

  create_table "idempotency_keys", force: :cascade do |t|
    t.bigint "api_token_id", null: false
    t.datetime "created_at", null: false
    t.datetime "expires_at"
    t.string "key", null: false
    t.string "request_fingerprint"
    t.jsonb "response_body"
    t.integer "response_status"
    t.datetime "updated_at", null: false
    t.index ["api_token_id", "key"], name: "index_idempotency_keys_on_token_and_key", unique: true
    t.index ["api_token_id"], name: "index_idempotency_keys_on_api_token_id"
  end

  create_table "model_assignments", force: :cascade do |t|
    t.bigint "ai_model_id", null: false
    t.datetime "created_at", null: false
    t.bigint "fallback_ai_model_id"
    t.string "function", null: false
    t.jsonb "options", default: {}, null: false
    t.bigint "scope_id"
    t.string "scope_type", null: false
    t.datetime "updated_at", null: false
    t.index ["ai_model_id"], name: "index_model_assignments_on_ai_model_id"
    t.index ["scope_type", "scope_id", "function"], name: "index_model_assignments_on_scope_and_function", unique: true
    t.check_constraint "jsonb_typeof(options) = 'object'::text", name: "model_assignments_options_is_object"
  end

  create_table "model_prices", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "currency", default: "USD"
    t.datetime "deprecated_at"
    t.datetime "effective_at"
    t.decimal "input_per_million", precision: 16, scale: 8
    t.string "model"
    t.decimal "output_per_million", precision: 16, scale: 8
    t.string "provider"
    t.datetime "updated_at", null: false
    t.index ["provider", "model", "effective_at"], name: "index_model_prices_on_provider_and_model_and_effective_at"
  end

  create_table "pages", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "name"
    t.string "prompt"
    t.bigint "template_id", null: false
    t.datetime "updated_at", null: false
    t.bigint "webapp_id"
    t.index ["template_id"], name: "index_pages_on_template_id"
    t.index ["webapp_id"], name: "index_pages_on_webapp_id"
  end

  create_table "scribe_audio_chunks", force: :cascade do |t|
    t.string "content_type"
    t.datetime "created_at", null: false
    t.boolean "final", default: false, null: false
    t.bigint "scribe_session_id", null: false
    t.integer "seq", null: false
    t.datetime "updated_at", null: false
    t.index ["scribe_session_id", "seq"], name: "index_scribe_audio_chunks_on_scribe_session_id_and_seq", unique: true
    t.index ["scribe_session_id"], name: "index_scribe_audio_chunks_on_scribe_session_id"
  end

  create_table "scribe_outputs", force: :cascade do |t|
    t.jsonb "context", default: {}, null: false
    t.datetime "created_at", null: false
    t.jsonb "inline_fields"
    t.string "output_type", null: false
    t.bigint "page_id"
    t.jsonb "result", default: {}, null: false
    t.jsonb "result_errors", default: [], null: false
    t.bigint "scribe_session_id", null: false
    t.string "status", default: "pending", null: false
    t.string "template_ref"
    t.datetime "updated_at", null: false
    t.index ["scribe_session_id"], name: "index_scribe_outputs_on_scribe_session_id"
  end

  create_table "scribe_sessions", force: :cascade do |t|
    t.bigint "account_id", null: false
    t.bigint "api_token_id"
    t.string "callback_url"
    t.datetime "created_at", null: false
    t.integer "document_pages", default: 0, null: false
    t.jsonb "error", default: {}, null: false
    t.datetime "expires_at"
    t.string "idempotency_key"
    t.string "language"
    t.string "modality", default: "audio", null: false
    t.string "mode", default: "consultation"
    t.string "status", default: "created", null: false
    t.datetime "updated_at", null: false
    t.bigint "user_id"
    t.index ["account_id", "created_at"], name: "index_scribe_sessions_on_account_id_and_created_at"
    t.index ["account_id"], name: "index_scribe_sessions_on_account_id"
    t.index ["api_token_id", "idempotency_key"], name: "index_scribe_sessions_on_token_and_idempotency_key", unique: true
    t.index ["api_token_id"], name: "index_scribe_sessions_on_api_token_id"
    t.index ["user_id"], name: "index_scribe_sessions_on_user_id"
  end

  add_check_constraint "scribe_sessions", "document_pages >= 0 AND document_pages <= 20", name: "scribe_sessions_document_pages_within_cap", validate: false

  create_table "scribe_transcript_segments", force: :cascade do |t|
    t.string "content_type"
    t.datetime "created_at", null: false
    t.float "duration_seconds"
    t.string "language"
    t.string "model"
    t.string "provider"
    t.bigint "scribe_session_id", null: false
    t.integer "seq", null: false
    t.string "status", default: "pending", null: false
    t.text "text"
    t.datetime "transcribed_at"
    t.datetime "updated_at", null: false
    t.index ["scribe_session_id", "seq"], name: "index_scribe_transcript_segments_on_scribe_session_id_and_seq", unique: true
    t.index ["scribe_session_id"], name: "index_scribe_transcript_segments_on_scribe_session_id"
  end

  create_table "templates", force: :cascade do |t|
    t.bigint "account_id"
    t.boolean "archived", default: false, null: false
    t.datetime "created_at", null: false
    t.string "description", null: false
    t.string "name", null: false
    t.datetime "updated_at", null: false
    t.index ["account_id"], name: "index_templates_on_account_id"
  end

  create_table "transcripts", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.decimal "duration_seconds", precision: 12, scale: 3, default: "0.0"
    t.string "language"
    t.string "model"
    t.string "provider"
    t.bigint "scribe_session_id", null: false
    t.jsonb "segments", default: []
    t.jsonb "speakers", default: []
    t.text "text"
    t.datetime "updated_at", null: false
    t.jsonb "words", default: []
    t.index ["scribe_session_id"], name: "index_transcripts_on_scribe_session_id"
  end

  create_table "usage_events", force: :cascade do |t|
    t.bigint "account_id", null: false
    t.bigint "api_token_id"
    t.decimal "audio_seconds", precision: 12, scale: 3, default: "0.0"
    t.decimal "cost", precision: 12, scale: 6
    t.decimal "cost_settlement", precision: 12, scale: 6
    t.datetime "created_at", null: false
    t.string "currency", default: "USD"
    t.string "dedupe_key"
    t.boolean "estimated", default: false, null: false
    t.string "function", null: false
    t.decimal "fx_rate", precision: 16, scale: 8
    t.integer "input_tokens", default: 0, null: false
    t.integer "latency_ms"
    t.string "model"
    t.string "model_version"
    t.integer "output_tokens", default: 0, null: false
    t.integer "pages", default: 0, null: false
    t.string "provider"
    t.string "request_id"
    t.datetime "reserved_until"
    t.bigint "scribe_output_id"
    t.bigint "scribe_session_id"
    t.string "status", default: "pending", null: false
    t.integer "total_tokens", default: 0, null: false
    t.decimal "unit_price_audio_min", precision: 16, scale: 8
    t.decimal "unit_price_input", precision: 16, scale: 8
    t.decimal "unit_price_output", precision: 16, scale: 8
    t.decimal "unit_price_page", precision: 16, scale: 8
    t.datetime "updated_at", null: false
    t.bigint "user_id"
    t.index ["account_id", "created_at"], name: "index_usage_events_on_account_id_and_created_at"
    t.index ["account_id", "model"], name: "index_usage_events_on_account_id_and_model"
    t.index ["account_id", "status"], name: "index_usage_events_on_account_id_and_status"
    t.index ["account_id"], name: "index_usage_events_on_account_id"
    t.index ["api_token_id", "dedupe_key"], name: "index_usage_events_on_token_and_dedupe_key", unique: true
    t.index ["api_token_id"], name: "index_usage_events_on_api_token_id"
    t.index ["scribe_session_id"], name: "index_usage_events_on_scribe_session_id"
    t.index ["status", "reserved_until"], name: "index_usage_events_on_status_and_reserved_until"
    t.index ["user_id", "created_at"], name: "index_usage_events_on_user_id_and_created_at"
  end

  create_table "usage_limits", force: :cascade do |t|
    t.bigint "account_id", null: false
    t.datetime "created_at", null: false
    t.decimal "limit_value", precision: 16, scale: 6, null: false
    t.string "metric", null: false
    t.string "period", null: false
    t.string "scope", null: false
    t.datetime "updated_at", null: false
    t.index ["account_id", "scope", "metric", "period"], name: "index_usage_limits_on_account_scope_metric_period", unique: true
  end

  create_table "users", force: :cascade do |t|
    t.bigint "account_id"
    t.boolean "admin"
    t.datetime "created_at", null: false
    t.string "email", default: "", null: false
    t.string "encrypted_password", default: "", null: false
    t.datetime "remember_created_at"
    t.datetime "reset_password_sent_at"
    t.string "reset_password_token"
    t.datetime "updated_at", null: false
    t.index ["account_id"], name: "index_users_on_account_id"
    t.index ["email"], name: "index_users_on_email", unique: true
    t.index ["reset_password_token"], name: "index_users_on_reset_password_token", unique: true
  end

  create_table "webapps", force: :cascade do |t|
    t.boolean "autofill"
    t.datetime "created_at", null: false
    t.string "fqdn"
    t.string "title"
    t.datetime "updated_at", null: false
    t.bigint "user_id"
    t.index ["user_id"], name: "index_webapps_on_user_id"
  end

  add_foreign_key "account_credits", "accounts"
  add_foreign_key "accounts", "accounts", column: "parent_id"
  add_foreign_key "active_storage_attachments", "active_storage_blobs", column: "blob_id"
  add_foreign_key "active_storage_variant_records", "active_storage_blobs", column: "blob_id"
  add_foreign_key "ai_models", "ai_providers"
  add_foreign_key "api_tokens", "accounts"
  add_foreign_key "api_tokens", "users"
  add_foreign_key "domains", "templates"
  add_foreign_key "form_fields", "pages"
  add_foreign_key "model_assignments", "ai_models"
  add_foreign_key "model_assignments", "ai_models", column: "fallback_ai_model_id"
  add_foreign_key "pages", "templates"
  add_foreign_key "pages", "webapps"
  add_foreign_key "scribe_audio_chunks", "scribe_sessions"
  add_foreign_key "scribe_outputs", "scribe_sessions"
  add_foreign_key "scribe_sessions", "accounts"
  add_foreign_key "scribe_transcript_segments", "scribe_sessions"
  add_foreign_key "templates", "accounts"
  add_foreign_key "transcripts", "scribe_sessions"
  add_foreign_key "usage_limits", "accounts"
  add_foreign_key "users", "accounts"
  add_foreign_key "webapps", "users"
end
