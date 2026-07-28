# Configure Active Record Encryption from ENV when present (local/CI). In
# production prefer Rails credentials (Rails reads them automatically); this
# initializer only overrides when the ENV keys are explicitly provided.
#
# The test environment falls back to fixed, non-secret keys so the suite never
# depends on a developer's .env or on CI secrets. Encrypted columns
# (AiProvider#api_key) hold only factory data there, and the keys are constants
# in a public repo — never reuse them anywhere real.
if ENV["AR_ENCRYPTION_PRIMARY_KEY"].present?
  ActiveRecord::Encryption.configure(
    primary_key: ENV["AR_ENCRYPTION_PRIMARY_KEY"],
    deterministic_key: ENV["AR_ENCRYPTION_DETERMINISTIC_KEY"],
    key_derivation_salt: ENV["AR_ENCRYPTION_KEY_DERIVATION_SALT"]
  )
elsif Rails.env.test?
  ActiveRecord::Encryption.configure(
    primary_key: "test_only_primary_key_not_a_secret_00",
    deterministic_key: "test_only_deterministic_key_not_secret",
    key_derivation_salt: "test_only_key_derivation_salt_not_secret"
  )
end
