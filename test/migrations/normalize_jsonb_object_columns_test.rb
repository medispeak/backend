require "test_helper"
require Rails.root.join("db/migrate/20260816100000_normalize_jsonb_object_columns.rb")

# The data migration is what repairs production rows that the admin UI stored
# as JSON string scalars, so it gets exercised directly against rows inserted
# with raw SQL (bypassing the model coercion, exactly like the broken rows).
class NormalizeJsonbObjectColumnsTest < ActiveSupport::TestCase
  setup do
    @model = create(:ai_model, capabilities: { "accepts_audio" => true })
    @conn = ActiveRecord::Base.connection

    # The test schema already carries the CHECK constraints this migration
    # adds, which (by design) make the broken rows below un-insertable. Drop
    # them for this test — DDL is transactional in Postgres, so the test
    # transaction rolls this back — and let #up re-add them.
    NormalizeJsonbObjectColumns::TARGETS.each do |table, column|
      @conn.remove_check_constraint(table, name: "#{table}_#{column}_is_object", if_exists: true)
    end
  end

  test "restores an object from a JSON-string scalar and resets junk to {}" do
    string_empty = raw_assignment("asr", %q('"{}"'))
    string_object = raw_assignment("structuring", %q('"{\"asr_mode\": \"translate\"}"'))
    junk_array = raw_assignment("ocr", "'[1, 2]'")
    already_ok = create(:model_assignment, scope_type: "Account", scope_id: create(:account).id,
                                           function: "asr", ai_model: @model,
                                           options: { "asr_mode" => "translate" })

    @conn.execute("UPDATE ai_models SET capabilities = '\"{\\\"can_transcribe\\\": true}\"'::jsonb WHERE id = #{@model.id}")
    assert_equal "string", typeof("ai_models", "capabilities", @model.id), "precondition"
    assert_equal "string", typeof("model_assignments", "options", string_empty), "precondition"

    silence_migration { NormalizeJsonbObjectColumns.new.up }

    assert_equal({}, ModelAssignment.find(string_empty).options)
    assert_equal({ "asr_mode" => "translate" }, ModelAssignment.find(string_object).options)
    assert_equal({}, ModelAssignment.find(junk_array).options)
    assert_equal({ "asr_mode" => "translate" }, already_ok.reload.options, "healthy rows are untouched")
    assert_equal({ "can_transcribe" => true }, @model.reload.capabilities)

    [ string_empty, string_object, junk_array, already_ok.id ].each do |id|
      assert_equal "object", typeof("model_assignments", "options", id)
    end
    assert_equal "object", typeof("ai_models", "capabilities", @model.id)

    assert_nothing_raised { Llm::ConfigResolver.call(function: :asr) }
  end

  test "adds a CHECK constraint so the incident write is impossible afterwards" do
    silence_migration { NormalizeJsonbObjectColumns.new.up }

    NormalizeJsonbObjectColumns::TARGETS.each do |table, column|
      assert @conn.check_constraint_exists?(table, name: "#{table}_#{column}_is_object"),
             "expected CHECK on #{table}.#{column}"
    end
    assert_raises(ActiveRecord::StatementInvalid) do
      @conn.transaction(requires_new: true) { raw_assignment("asr", %q('"{}"')) }
    end
  end

  test "also normalizes accounts.settings and form_fields.metadata" do
    account = create(:account)
    field = create(:form_field)
    @conn.execute(%Q(UPDATE accounts SET settings = '"{\\"rpm\\": 300}"'::jsonb WHERE id = #{account.id}))
    @conn.execute("UPDATE form_fields SET metadata = '\"junk\"'::jsonb WHERE id = #{field.id}")
    assert_equal "string", typeof("accounts", "settings", account.id), "precondition"
    assert_equal "string", typeof("form_fields", "metadata", field.id), "precondition"

    silence_migration { NormalizeJsonbObjectColumns.new.up }

    assert_equal({ "rpm" => 300 }, account.reload.settings)
    assert_equal({}, field.reload.metadata)
    assert_equal "object", typeof("accounts", "settings", account.id)
    assert_equal "object", typeof("form_fields", "metadata", field.id)
  end

  test "is idempotent: a second run issues no UPDATE and re-adds no constraint" do
    id = raw_assignment("asr", %q('"{}"'))
    silence_migration { NormalizeJsonbObjectColumns.new.up }

    writes = []
    subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |*, payload|
      writes << payload[:sql] if payload[:sql] =~ /\A\s*(UPDATE|ALTER TABLE)/i
    end
    begin
      silence_migration { NormalizeJsonbObjectColumns.new.up }
    ensure
      ActiveSupport::Notifications.unsubscribe(subscriber)
    end

    assert_empty writes, "second run should be a no-op, got: #{writes.inspect}"
    assert_equal({}, ModelAssignment.find(id).options)
  end

  private

  # Inserts a System-scope assignment with the given raw jsonb literal for
  # options, exactly as a broken row sits in the database.
  def raw_assignment(function, options_literal)
    @conn.select_value(<<~SQL)
      INSERT INTO model_assignments (scope_type, scope_id, function, ai_model_id, options, created_at, updated_at)
      VALUES ('System', NULL, '#{function}', #{@model.id}, #{options_literal}::jsonb, now(), now())
      RETURNING id
    SQL
  end

  def typeof(table, column, id)
    @conn.select_value("SELECT jsonb_typeof(#{column}) FROM #{table} WHERE id = #{id.to_i}")
  end

  def silence_migration
    was = ActiveRecord::Migration.verbose
    ActiveRecord::Migration.verbose = false
    yield
  ensure
    ActiveRecord::Migration.verbose = was
  end
end
