# Versioned price rows: a NULL effective_at means "in force from the start" and
# a NULL deprecated_at means "not yet retired".
module EffectiveDated
  extend ActiveSupport::Concern

  included do
    # NULLS LAST is the whole point of the ordering: Postgres sorts NULLs FIRST
    # for DESC, so without it an undated row outranks every dated one and a
    # newer price never takes effect until the old row is deprecated.
    scope :current, ->(at = Time.current) {
      where("effective_at IS NULL OR effective_at <= ?", at)
        .where("deprecated_at IS NULL OR deprecated_at > ?", at)
        .order(Arel.sql("effective_at DESC NULLS LAST"))
    }
  end
end
