# This file is idempotent: re-running `bin/rails db:seed` will not raise and will
# not create duplicate records. Natural keys are used with find_or_create_by, and
# other attributes are assigned inside the block / via update.

# Create a user (natural key: email)
user = User.find_or_create_by!(email: 'admin@example.com') do |u|
  u.password = 'password123'
  u.password_confirmation = 'password123'
  u.admin = true
end

# Create the Care template (natural key: name)
care_template = Template.find_or_create_by!(name: 'Care') do |t|
  t.description = 'Template for Care EMR'
end

# Create domains for the Care template (natural key: fqdn)
care_domains = [ "care.ohc.network", "care.do.ohc.network" ]

care_domains.each do |fqdn|
  Domain.find_or_create_by!(fqdn: fqdn) do |d|
    d.template = care_template
    d.archived = false
  end
end

# Create the Medispeak template (natural key: name)
medispeak_template = Template.find_or_create_by!(name: 'Medispeak') do |t|
  t.description = 'Medispeak demo EMR'
end

demo_app_domains = [ "localhost:5173", "www.medispeak.in" ]

demo_app_domains.each do |fqdn|
  Domain.find_or_create_by!(fqdn: fqdn) do |d|
    d.template = medispeak_template
    d.archived = false
  end
end

# Create pages for the Care template (natural key: name + template)
consultation_form = Page.find_or_create_by!(name: 'Consultation Form', template: care_template)

log_update = Page.find_or_create_by!(name: 'Log Update', template: care_template)

# Create page for the Medispeak template (natural key: name + template)
medispeak_demo_page = Page.find_or_create_by!(name: 'Demo Page 1', template: medispeak_template)

# Create form fields for the Consultation Form page (Care template)
consultation_form_fields = [
  {
    title: "history_of_present_illness",
    friendly_name: "History of Present Illness",
    description: "Details about the current illness, including when",
    field_type: "string"
  },
  {
    title: "examination_details",
    friendly_name: "Examination Details",
    description: "Details about the examination performed and clinic",
    field_type: "string"
  },
  {
    title: "weight",
    friendly_name: "Weight",
    description: "The patient's weight, usually measured in kilogram",
    field_type: "number",
    minimum: 0,
    maximum: 500
  },
  {
    title: "height",
    friendly_name: "Height",
    description: "The patient's height, usually measured in centimeters",
    field_type: "number",
    minimum: 0,
    maximum: 300
  },
  {
    title: "consultation_notes",
    friendly_name: "Consultation Notes",
    description: "General Advice given to the patient",
    field_type: "string"
  },
  {
    title: "special_instruction",
    friendly_name: "Special Instructions",
    description: "Any special instructions for the patient or other",
    field_type: "string"
  },
  {
    title: "treatment_plan",
    friendly_name: "Treatment Plan",
    description: "Treatment plan for the patient, including prescriptions",
    field_type: "string"
  },
  {
    title: "patient_no",
    friendly_name: "Patient Number",
    description: "The inpatient or out patient number assigned to the patient",
    field_type: "string"
  }
]

# Create form fields for the Log Update page (Care template)
log_update_fields = [
  {
    title: "physical_examination_info",
    friendly_name: "Physical Examination Info",
    description: "Physical Examination Details, including any complaints",
    field_type: "string"
  },
  {
    title: "other_details",
    friendly_name: "Other Details",
    description: "Other details, including Treatment Plans, Advice",
    field_type: "string"
  },
  {
    title: "diastolic",
    friendly_name: "Diastolic BP",
    description: "Blood Pressure Diastolic as integer",
    field_type: "number",
    minimum: 0,
    maximum: 200
  },
  {
    title: "systolic",
    friendly_name: "Systolic BP",
    description: "Blood Pressure Systolic as integer",
    field_type: "number",
    minimum: 0,
    maximum: 300
  },
  {
    title: "temperature",
    friendly_name: "Temperature",
    description: "Temperature in Fahrenheit",
    field_type: "number",
    minimum: 90,
    maximum: 110
  },
  {
    title: "resp",
    friendly_name: "Respiratory Rate",
    description: "Respiratory Rate as integer",
    field_type: "number",
    minimum: 0,
    maximum: 100
  },
  {
    title: "spo2",
    friendly_name: "SPO2",
    description: "SPO2 Value as integer",
    field_type: "number",
    minimum: 0,
    maximum: 100
  },
  {
    title: "pulse",
    friendly_name: "Pulse Rate",
    description: "Pulse Rate as integer",
    field_type: "number",
    minimum: 0,
    maximum: 300
  }
]

# Create form fields for the Demo Page 1 (Medispeak template)
medispeak_demo_fields = [
  {
    title: "gender",
    friendly_name: "Gender",
    description: "Gender from options Male, Female, Other",
    field_type: "single_select",
    enum_options: [ "Male", "Female", "Other" ]
  },
  {
    title: "symptoms",
    friendly_name: "Symptoms",
    description: "Applicable Symptoms from options",
    field_type: "multi_select",
    enum_options: [ "Headache", "Fever", "Cough", "Cold", "Body Pain" ]
  },
  {
    title: "preferred_time",
    friendly_name: "Preferred Time",
    description: "The Preferred Time from the options",
    field_type: "single_select",
    enum_options: [ "Morning", "Afternoon", "Evening" ]
  },
  {
    title: "full_name",
    friendly_name: "Full Name",
    description: "Full name",
    field_type: "string"
  },
  {
    title: "age",
    friendly_name: "Age",
    description: "Age of the user",
    field_type: "number",
    minimum: 0,
    maximum: 150
  },
  {
    title: "email",
    friendly_name: "Email",
    description: "Email of the user",
    field_type: "string"
  },
  {
    title: "phone_number",
    friendly_name: "Phone Number",
    description: "Phone Number of the user",
    field_type: "string"
  },
  {
    title: "additional_notes",
    friendly_name: "Additional Notes",
    description: "Full text of the conversation",
    field_type: "string"
  },
  {
    title: "date_of_birth",
    friendly_name: "Date of Birth",
    description: "Date of Birth as a Javascript Date String",
    field_type: "string"
  }
]

# Create form fields for each page (natural key: title + page)
[
  [ consultation_form, consultation_form_fields ],
  [ log_update, log_update_fields ],
  [ medispeak_demo_page, medispeak_demo_fields ]
].each do |page, fields|
  fields.each do |field_data|
    FormField.find_or_create_by!(page: page, title: field_data[:title]) do |field|
      field.friendly_name = field_data[:friendly_name]
      field.description = field_data[:description]
      field.field_type = field_data[:field_type]
      field.minimum = field_data[:minimum]
      field.maximum = field_data[:maximum]
      field.enum_options = field_data[:enum_options] if field_data[:enum_options].present?
    end
  end
end

# ---------------------------------------------------------------------------
# AI configuration (model-agnostic engine)
#
# Seeds providers, models, default assignments, and pricing so the operator can
# use the system immediately. Everything below is idempotent (find_or_create_by
# on natural keys). API keys are pulled from ENV when present; providers whose
# key env var is absent are still created with a placeholder so they appear in
# the admin UI and can have a key filled in later.
# ---------------------------------------------------------------------------

# Providers (natural key: name)
#
# For ruby-openai, base_url is the host root; the client appends /v1. So OpenAI
# is "https://api.openai.com/" and OpenRouter is "https://openrouter.ai/api/".
# The Anthropic adapter posts to base_url + "/v1/messages".
# A "run your own model" provider is simply an openai_compatible provider whose
# base_url points at a self-hosted server (e.g. faster-whisper on localhost).

openai_provider = AiProvider.find_or_create_by!(name: "OpenAI") do |p|
  p.kind = "openai_compatible"
  p.base_url = "https://api.openai.com/"
  # Set api_key only when the ENV value is present (guard nils).
  p.api_key = ENV["OPENAI_ACCESS_TOKEN"] if ENV["OPENAI_ACCESS_TOKEN"].present?
  p.organization_id = ENV["OPENAI_ORGANIZATION_ID"] if ENV["OPENAI_ORGANIZATION_ID"].present?
end

openrouter_provider = AiProvider.find_or_create_by!(name: "OpenRouter") do |p|
  p.kind = "openai_compatible"
  p.base_url = "https://openrouter.ai/api/"
  # OPENROUTER_API_KEY may be absent; create with placeholder so it shows in UI.
  p.api_key = ENV["OPENROUTER_API_KEY"].presence || "set-your-openrouter-api-key"
end

anthropic_provider = AiProvider.find_or_create_by!(name: "Anthropic") do |p|
  p.kind = "anthropic"
  p.base_url = "https://api.anthropic.com"
  # ANTHROPIC_API_KEY may be absent; create with placeholder so it shows in UI.
  p.api_key = ENV["ANTHROPIC_API_KEY"].presence || "set-your-anthropic-api-key"
end

# Example "run your own model" provider: a self-hosted, OpenAI-compatible server
# (e.g. faster-whisper served via an OpenAI-compatible API on localhost:8000).
self_hosted_provider = AiProvider.find_or_create_by!(name: "Self-hosted Whisper") do |p|
  p.kind = "openai_compatible"
  p.base_url = "http://localhost:8000/"
  p.api_key = "not-needed"
end

# Models (natural key: api_model_id + ai_provider)
whisper_model = AiModel.find_or_create_by!(ai_provider: openai_provider, api_model_id: "whisper-1") do |m|
  m.display_name = "Whisper v2 (OpenAI)"
  m.capabilities = { "accepts_audio" => true, "can_transcribe" => true }
end

gpt_4o_mini_model = AiModel.find_or_create_by!(ai_provider: openai_provider, api_model_id: "gpt-4o-mini") do |m|
  m.display_name = "GPT-4o mini"
  m.capabilities = {
    "can_structure" => true,
    "supports_json_schema" => true,
    "supports_function_calling" => true
  }
end

gpt_4o_transcribe_model = AiModel.find_or_create_by!(ai_provider: openai_provider, api_model_id: "gpt-4o-transcribe") do |m|
  m.display_name = "GPT-4o transcribe"
  m.capabilities = { "accepts_audio" => true, "can_transcribe" => true }
end

# Fast structuring model: benchmarked ~1.4s vs gpt-4o-mini ~1.5-3.3s and the
# gpt-5 series ~3.5-9s (reasoning overhead). Newer than the 4o family and the
# best speed/accuracy fit for clinical form extraction.
gpt_4_1_mini_model = AiModel.find_or_create_by!(ai_provider: openai_provider, api_model_id: "gpt-4.1-mini") do |m|
  m.display_name = "GPT-4.1 mini"
  m.capabilities = {
    "can_structure" => true,
    "supports_json_schema" => true,
    "supports_function_calling" => true
  }
end

llama_model = AiModel.find_or_create_by!(ai_provider: openrouter_provider, api_model_id: "meta-llama/llama-3.3-70b-instruct") do |m|
  m.display_name = "Llama 3.3 70B (open source)"
  m.capabilities = {
    "can_structure" => true,
    "supports_json_schema" => true,
    "supports_function_calling" => true
  }
end

haiku_model = AiModel.find_or_create_by!(ai_provider: anthropic_provider, api_model_id: "claude-3-5-haiku-latest") do |m|
  m.display_name = "Claude 3.5 Haiku"
  m.capabilities = {
    "can_structure" => true,
    "supports_function_calling" => true
  }
end

faster_whisper_model = AiModel.find_or_create_by!(ai_provider: self_hosted_provider, api_model_id: "Systran/faster-whisper-large-v3") do |m|
  m.display_name = "faster-whisper large-v3 (self-hosted)"
  m.capabilities = { "accepts_audio" => true, "can_transcribe" => true }
end

# System-wide default assignments (natural key: scope_type + scope_id + function).
# scope_id is nil for System scope.
ModelAssignment.find_or_create_by!(scope_type: "System", scope_id: nil, function: "asr") do |a|
  a.ai_model = whisper_model
end

ModelAssignment.find_or_create_by!(scope_type: "System", scope_id: nil, function: "structuring") do |a|
  a.ai_model = gpt_4_1_mini_model
end

# Demonstration Page-scoped assignment showing mix-and-match across providers:
# the "Consultation Form" page uses open-source Llama 3.3 70B (via OpenRouter)
# for structuring, while ASR still resolves to OpenAI Whisper from the System
# default. This proves you can pair an open-source structuring model with an
# OpenAI ASR model on a per-page basis. gpt-4o-mini is set as the fallback.
if consultation_form.present?
  ModelAssignment.find_or_create_by!(scope_type: "Page", scope_id: consultation_form.id, function: "structuring") do |a|
    a.ai_model = llama_model
    a.fallback_ai_model = gpt_4o_mini_model
  end
end

# Pricing (text/token models). Natural key: provider + model.
ModelPrice.find_or_create_by!(provider: "OpenAI", model: "gpt-4o-mini") do |mp|
  mp.input_per_million = 0.15
  mp.output_per_million = 0.60
  mp.currency = "USD"
  mp.effective_at = Time.current
end

# gpt-4o-transcribe token pricing (approximate).
ModelPrice.find_or_create_by!(provider: "OpenAI", model: "gpt-4o-transcribe") do |mp|
  mp.input_per_million = 2.50
  mp.output_per_million = 10.00
  mp.currency = "USD"
  mp.effective_at = Time.current
end

ModelPrice.find_or_create_by!(provider: "OpenRouter", model: "meta-llama/llama-3.3-70b-instruct") do |mp|
  mp.input_per_million = 0.13
  mp.output_per_million = 0.40
  mp.currency = "USD"
  mp.effective_at = Time.current
end

# Audio pricing (per-minute). Natural key: provider + model.
AudioModelPrice.find_or_create_by!(provider: "OpenAI", model: "whisper-1") do |amp|
  amp.price_per_minute = 0.006
  amp.currency = "USD"
  amp.effective_at = Time.current
end

AudioModelPrice.find_or_create_by!(provider: "OpenAI", model: "gpt-4o-transcribe") do |amp|
  amp.price_per_minute = 0.006
  amp.currency = "USD"
  amp.effective_at = Time.current
end

# Credits for the admin user's account so it can immediately run metered calls.
admin_account = User.find_by(email: "admin@example.com")&.account
if admin_account.present?
  AccountCredit.find_or_create_by!(account: admin_account) do |c|
    c.balance = 100.0
    c.credit_limit = 100.0
  end

  # Per-account rate limit (requests per minute) consumed by the rate limiter.
  admin_account.settings["rpm"] = 120
  admin_account.save!
end

puts "Seeds created successfully!"
puts "User email: #{user.email}"
puts "Care Template: #{care_template.name}"
puts "Medispeak Template: #{medispeak_template.name}"
puts "Total Domains created: #{Domain.count}"
puts "Total Pages created: #{Page.count}"
puts "Form fields created for Consultation Form: #{consultation_form.form_fields.count}"
puts "Form fields created for Log Update: #{log_update.form_fields.count}"
puts "Form fields created for Medispeak Demo Page 1: #{medispeak_demo_page.form_fields.count}"
puts "AI Providers: #{AiProvider.count}"
puts "AI Models: #{AiModel.count}"
puts "Model Assignments: #{ModelAssignment.count}"
