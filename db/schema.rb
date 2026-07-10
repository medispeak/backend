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

ActiveRecord::Schema[8.0].define(version: 2026_07_10_120000) do
  # These are extensions that must be enabled in order to support this database
  enable_extension "pg_catalog.plpgsql"

  create_table "account_credits", force: :cascade do |t|
    t.bigint "account_id", null: false
    t.decimal "balance", precision: 16, scale: 6, default: "0.0", null: false
    t.decimal "credit_limit", precision: 16, scale: 6
    t.string "refill_period"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["account_id"], name: "index_account_credits_on_account_id", unique: true
  end

  create_table "accounts", force: :cascade do |t|
    t.string "name", null: false
    t.string "status", default: "active", null: false
    t.jsonb "settings", default: {}, null: false
    t.string "webhook_secret"
    t.string "default_callback_url"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
  end

  create_table "active_storage_attachments", force: :cascade do |t|
    t.string "name", null: false
    t.string "record_type", null: false
    t.bigint "record_id", null: false
    t.bigint "blob_id", null: false
    t.datetime "created_at", null: false
    t.index ["blob_id"], name: "index_active_storage_attachments_on_blob_id"
    t.index ["record_type", "record_id", "name", "blob_id"], name: "index_active_storage_attachments_uniqueness", unique: true
  end

  create_table "active_storage_blobs", force: :cascade do |t|
    t.string "key", null: false
    t.string "filename", null: false
    t.string "content_type"
    t.text "metadata"
    t.string "service_name", null: false
    t.bigint "byte_size", null: false
    t.string "checksum"
    t.datetime "created_at", null: false
    t.index ["key"], name: "index_active_storage_blobs_on_key", unique: true
  end

  create_table "active_storage_variant_records", force: :cascade do |t|
    t.bigint "blob_id", null: false
    t.string "variation_digest", null: false
    t.index ["blob_id", "variation_digest"], name: "index_active_storage_variant_records_uniqueness", unique: true
  end

  create_table "ai_models", force: :cascade do |t|
    t.bigint "ai_provider_id", null: false
    t.string "api_model_id", null: false
    t.string "display_name"
    t.jsonb "capabilities", default: {}, null: false
    t.boolean "active", default: true, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["ai_provider_id"], name: "index_ai_models_on_ai_provider_id"
  end

  create_table "ai_providers", force: :cascade do |t|
    t.string "name", null: false
    t.string "kind", null: false
    t.string "base_url"
    t.text "api_key"
    t.string "organization_id"
    t.integer "request_timeout", default: 120, null: false
    t.boolean "active", default: true, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
  end

  create_table "api_tokens", force: :cascade do |t|
    t.string "name"
    t.bigint "user_id", null: false
    t.datetime "last_used_at"
    t.datetime "expires_at"
    t.boolean "active", default: true, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.bigint "account_id"
    t.string "token_digest"
    t.string "token_prefix"
    t.string "scopes", default: [], array: true
    t.index ["account_id"], name: "index_api_tokens_on_account_id"
    t.index ["token_digest"], name: "index_api_tokens_on_token_digest", unique: true
    t.index ["user_id"], name: "index_api_tokens_on_user_id"
  end

  create_table "audio_model_prices", force: :cascade do |t|
    t.string "provider"
    t.string "model"
    t.decimal "price_per_minute", precision: 16, scale: 8
    t.string "currency", default: "USD"
    t.datetime "effective_at"
    t.datetime "deprecated_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["provider", "model", "effective_at"], name: "idx_on_provider_model_effective_at_ef696c0068"
  end

  create_table "credit_transactions", force: :cascade do |t|
    t.bigint "account_id", null: false
    t.string "txn_type", null: false
    t.decimal "amount", precision: 16, scale: 6, null: false
    t.decimal "balance_before", precision: 16, scale: 6
    t.decimal "balance_after", precision: 16, scale: 6
    t.bigint "usage_event_id"
    t.bigint "scribe_session_id"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["account_id"], name: "index_credit_transactions_on_account_id"
    t.index ["usage_event_id", "txn_type"], name: "index_credit_transactions_on_usage_event_and_type", unique: true
  end

  create_table "domains", force: :cascade do |t|
    t.bigint "template_id", null: false
    t.string "fqdn", null: false
    t.boolean "archived", default: false, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["template_id"], name: "index_domains_on_template_id"
  end

  create_table "form_fields", force: :cascade do |t|
    t.string "title"
    t.string "description"
    t.bigint "page_id", null: false
    t.jsonb "metadata", default: {}, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.string "friendly_name", null: false
    t.string "field_type", default: "string", null: false
    t.string "minimum"
    t.string "maximum"
    t.string "enum_options", default: [], array: true
    t.index ["page_id"], name: "index_form_fields_on_page_id"
  end

  create_table "idempotency_keys", force: :cascade do |t|
    t.bigint "api_token_id", null: false
    t.string "key", null: false
    t.string "request_fingerprint"
    t.jsonb "response_body"
    t.integer "response_status"
    t.datetime "expires_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["api_token_id", "key"], name: "index_idempotency_keys_on_token_and_key", unique: true
    t.index ["api_token_id"], name: "index_idempotency_keys_on_api_token_id"
  end

  create_table "model_assignments", force: :cascade do |t|
    t.string "scope_type", null: false
    t.bigint "scope_id"
    t.string "function", null: false
    t.bigint "ai_model_id", null: false
    t.bigint "fallback_ai_model_id"
    t.jsonb "options", default: {}, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["ai_model_id"], name: "index_model_assignments_on_ai_model_id"
    t.index ["scope_type", "scope_id", "function"], name: "index_model_assignments_on_scope_and_function", unique: true
  end

  create_table "model_prices", force: :cascade do |t|
    t.string "provider"
    t.string "model"
    t.decimal "input_per_million", precision: 16, scale: 8
    t.decimal "output_per_million", precision: 16, scale: 8
    t.string "currency", default: "USD"
    t.datetime "effective_at"
    t.datetime "deprecated_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["provider", "model", "effective_at"], name: "index_model_prices_on_provider_and_model_and_effective_at"
  end

  create_table "pages", force: :cascade do |t|
    t.bigint "webapp_id"
    t.bigint "template_id", null: false
    t.string "name"
    t.string "prompt"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["template_id"], name: "index_pages_on_template_id"
    t.index ["webapp_id"], name: "index_pages_on_webapp_id"
  end

  create_table "scribe_outputs", force: :cascade do |t|
    t.bigint "scribe_session_id", null: false
    t.string "output_type", null: false
    t.bigint "page_id"
    t.string "template_ref"
    t.jsonb "context", default: {}, null: false
    t.string "status", default: "pending", null: false
    t.jsonb "result", default: {}, null: false
    t.jsonb "result_errors", default: [], null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.jsonb "inline_fields"
    t.index ["scribe_session_id"], name: "index_scribe_outputs_on_scribe_session_id"
  end

  create_table "scribe_sessions", force: :cascade do |t|
    t.bigint "account_id", null: false
    t.bigint "api_token_id"
    t.bigint "user_id"
    t.string "status", default: "created", null: false
    t.string "language"
    t.string "mode", default: "consultation"
    t.string "idempotency_key"
    t.string "callback_url"
    t.datetime "expires_at"
    t.jsonb "error", default: {}, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["account_id", "created_at"], name: "index_scribe_sessions_on_account_id_and_created_at"
    t.index ["account_id"], name: "index_scribe_sessions_on_account_id"
    t.index ["api_token_id", "idempotency_key"], name: "index_scribe_sessions_on_token_and_idempotency_key", unique: true
    t.index ["api_token_id"], name: "index_scribe_sessions_on_api_token_id"
    t.index ["user_id"], name: "index_scribe_sessions_on_user_id"
  end

  create_table "templates", force: :cascade do |t|
    t.string "name", null: false
    t.string "description", null: false
    t.boolean "archived", default: false, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.bigint "account_id"
    t.index ["account_id"], name: "index_templates_on_account_id"
  end

  create_table "transcriptions", force: :cascade do |t|
    t.bigint "user_id", null: false
    t.bigint "page_id", null: false
    t.jsonb "ai_response", default: {}, null: false
    t.text "transcription_text"
    t.string "status", default: "pending", null: false
    t.integer "duration", default: 0
    t.integer "prompt_tokens", default: 0
    t.integer "completion_tokens", default: 0
    t.integer "total_tokens", default: 0
    t.jsonb "context", default: {}, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["page_id"], name: "index_transcriptions_on_page_id"
    t.index ["user_id"], name: "index_transcriptions_on_user_id"
  end

  create_table "transcripts", force: :cascade do |t|
    t.bigint "scribe_session_id", null: false
    t.text "text"
    t.string "language"
    t.decimal "duration_seconds", precision: 12, scale: 3, default: "0.0"
    t.string "provider"
    t.string "model"
    t.jsonb "segments", default: []
    t.jsonb "words", default: []
    t.jsonb "speakers", default: []
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["scribe_session_id"], name: "index_transcripts_on_scribe_session_id"
  end

  create_table "usage_events", force: :cascade do |t|
    t.bigint "account_id", null: false
    t.bigint "api_token_id"
    t.bigint "scribe_session_id"
    t.bigint "scribe_output_id"
    t.string "function", null: false
    t.string "provider"
    t.string "model"
    t.string "model_version"
    t.integer "input_tokens", default: 0, null: false
    t.integer "output_tokens", default: 0, null: false
    t.integer "total_tokens", default: 0, null: false
    t.decimal "audio_seconds", precision: 12, scale: 3, default: "0.0"
    t.boolean "estimated", default: false, null: false
    t.decimal "unit_price_input", precision: 16, scale: 8
    t.decimal "unit_price_output", precision: 16, scale: 8
    t.decimal "unit_price_audio_min", precision: 16, scale: 8
    t.decimal "cost", precision: 12, scale: 6
    t.string "currency", default: "USD"
    t.decimal "fx_rate", precision: 16, scale: 8
    t.decimal "cost_settlement", precision: 12, scale: 6
    t.integer "latency_ms"
    t.string "status", default: "pending", null: false
    t.string "request_id"
    t.datetime "reserved_until"
    t.string "dedupe_key"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["account_id", "created_at"], name: "index_usage_events_on_account_id_and_created_at"
    t.index ["account_id", "model"], name: "index_usage_events_on_account_id_and_model"
    t.index ["account_id", "status"], name: "index_usage_events_on_account_id_and_status"
    t.index ["account_id"], name: "index_usage_events_on_account_id"
    t.index ["api_token_id", "dedupe_key"], name: "index_usage_events_on_token_and_dedupe_key", unique: true
    t.index ["api_token_id"], name: "index_usage_events_on_api_token_id"
    t.index ["status", "reserved_until"], name: "index_usage_events_on_status_and_reserved_until"
  end

  create_table "users", force: :cascade do |t|
    t.string "email", default: "", null: false
    t.string "encrypted_password", default: "", null: false
    t.string "reset_password_token"
    t.datetime "reset_password_sent_at"
    t.datetime "remember_created_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.boolean "admin"
    t.bigint "account_id"
    t.index ["account_id"], name: "index_users_on_account_id"
    t.index ["email"], name: "index_users_on_email", unique: true
    t.index ["reset_password_token"], name: "index_users_on_reset_password_token", unique: true
  end

  create_table "webapps", force: :cascade do |t|
    t.string "title"
    t.string "fqdn"
    t.boolean "autofill"
    t.bigint "user_id"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["user_id"], name: "index_webapps_on_user_id"
  end

  add_foreign_key "account_credits", "accounts"
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
  add_foreign_key "scribe_outputs", "scribe_sessions"
  add_foreign_key "scribe_sessions", "accounts"
  add_foreign_key "templates", "accounts"
  add_foreign_key "transcriptions", "pages"
  add_foreign_key "transcriptions", "users"
  add_foreign_key "transcripts", "scribe_sessions"
  add_foreign_key "users", "accounts"
  add_foreign_key "webapps", "users"
end
