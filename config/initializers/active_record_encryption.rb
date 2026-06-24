# Configure Active Record Encryption from ENV when present (local/CI). In
# production prefer Rails credentials (Rails reads them automatically); this
# initializer only overrides when the ENV keys are explicitly provided.
if ENV["AR_ENCRYPTION_PRIMARY_KEY"].present?
  ActiveRecord::Encryption.configure(
    primary_key: ENV["AR_ENCRYPTION_PRIMARY_KEY"],
    deterministic_key: ENV["AR_ENCRYPTION_DETERMINISTIC_KEY"],
    key_derivation_salt: ENV["AR_ENCRYPTION_KEY_DERIVATION_SALT"]
  )
end
