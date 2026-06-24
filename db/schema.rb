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

ActiveRecord::Schema[8.0].define(version: 2026_06_24_150003) do
  # These are extensions that must be enabled in order to support this database
  enable_extension "pg_catalog.plpgsql"

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
    t.string "token", null: false
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
    t.index ["token"], name: "index_api_tokens_on_token", unique: true
    t.index ["token_digest"], name: "index_api_tokens_on_token_digest", unique: true
    t.index ["user_id"], name: "index_api_tokens_on_user_id"
  end

  create_table "delayed_jobs", force: :cascade do |t|
    t.integer "priority", default: 0, null: false
    t.integer "attempts", default: 0, null: false
    t.text "handler", null: false
    t.text "last_error"
    t.datetime "run_at"
    t.datetime "locked_at"
    t.datetime "failed_at"
    t.string "locked_by"
    t.string "queue"
    t.datetime "created_at"
    t.datetime "updated_at"
    t.index ["priority", "run_at"], name: "delayed_jobs_priority"
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

  create_table "templates", force: :cascade do |t|
    t.string "name", null: false
    t.string "description", null: false
    t.boolean "archived", default: false, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
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
  add_foreign_key "transcriptions", "pages"
  add_foreign_key "transcriptions", "users"
  add_foreign_key "users", "accounts"
  add_foreign_key "webapps", "users"
end
