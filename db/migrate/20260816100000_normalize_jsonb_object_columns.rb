# Repairs jsonb columns that must hold a JSON object but were persisted as a
# JSON *string* scalar (or any other non-object) by the admin UI's text
# field, then locks the invariant in at the database. In production on
# 2026-08-16, model_assignments #1 (System/asr) and #5 (Account/asr) held
# '"{}"' (jsonb_typeof = 'string'), which reached Llm::ConfigResolver as a
# Ruby String and failed every ASR call with
# `undefined method 'each_with_object' for an instance of String`.
#
# For each non-object row: if the scalar is JSON text that parses to an
# object, that object is restored; otherwise the row is reset to {} — a
# non-object value was never usable by the resolver, so nothing meaningful is
# lost, and {} is the column default. Raw SQL on purpose: a data migration
# must not depend on model validations (see JsonObjectColumns).
#
# Then a CHECK (jsonb_typeof(col) = 'object') per column: the model coercion
# covers ActiveRecord writers, but update_column / update_all / insert_all /
# psql bypass it, and this constraint would by itself have made the incident
# write impossible. Idempotent (if_not_exists) so re-running is a no-op.
class NormalizeJsonbObjectColumns < ActiveRecord::Migration[8.0]
  # Every jsonb object column the admin UI edits as text (see the models'
  # `json_object_columns` declarations). Kept in sync with those so the
  # validation the concern adds can never trip on a pre-existing scalar row.
  TARGETS = [
    [ "model_assignments", "options" ],
    [ "ai_models", "capabilities" ],
    [ "accounts", "settings" ],
    [ "form_fields", "metadata" ]
  ].freeze

  def up
    TARGETS.each do |table, column|
      rows = select_rows(
        "SELECT id, #{column}::text FROM #{table} WHERE jsonb_typeof(#{column}) IS DISTINCT FROM 'object'"
      )

      rows.each do |id, raw|
        replacement = restore_object(raw)
        say "#{table}##{id}.#{column}: #{raw.inspect} -> #{replacement.inspect}"
        execute <<~SQL
          UPDATE #{table} SET #{column} = #{quote(JSON.generate(replacement))}::jsonb WHERE id = #{id.to_i}
        SQL
      end

      add_check_constraint table, "jsonb_typeof(#{column}) = 'object'",
                           name: constraint_name(table, column), if_not_exists: true
    end
  end

  def down
    # The malformed scalars are not worth restoring; only the constraints go.
    TARGETS.each do |table, column|
      remove_check_constraint table, name: constraint_name(table, column), if_exists: true
    end
  end

  private

  def constraint_name(table, column)
    "#{table}_#{column}_is_object"
  end

  # raw is the jsonb value rendered as text, e.g. "\"{}\"" for the string
  # scalar "{}". Unwrap one JSON layer; if that yields text that itself parses
  # to an object (the admin-form case), use it. Everything else -> {}.
  # A restored object containing U+0000 is also treated as junk: Postgres
  # cannot store NUL in jsonb and a per-row failure would abort the whole
  # migration (and with it `db:prepare` at boot).
  def restore_object(raw)
    return {} if raw.nil?

    scalar = JSON.parse(raw)
    return scalar if scalar.is_a?(Hash) && !contains_nul?(scalar)
    return {} unless scalar.is_a?(String)

    inner = JSON.parse(scalar)
    inner.is_a?(Hash) && !contains_nul?(inner) ? inner : {}
  rescue JSON::ParserError
    {}
  end

  def contains_nul?(hash)
    JSON.generate(hash).include?("\\u0000")
  end
end
