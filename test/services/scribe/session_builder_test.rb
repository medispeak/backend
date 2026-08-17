require "test_helper"

module Scribe
  class SessionBuilderTest < ActiveSupport::TestCase
    setup do
      @account = create(:account)
      @template = create(:template, account: @account)
      @page = create(:page, template: @template)
      create(:form_field, page: @page, title: "chief_complaint", field_type: "string")
    end

    def build(outputs:, account: @account, **overrides)
      SessionBuilder.new(account: account, outputs: outputs, **overrides).call
    end

    test "builds a session and one output per declaration" do
      second = create(:page, template: @template)

      result = build(outputs: [
        { type: "transcript" },
        { type: "form", page_id: @page.id },
        { type: "form", page_id: second.id }
      ])

      assert result.success?
      assert_equal @account, result.session.account
      assert_equal "created", result.session.status
      assert_equal "pending", result.session.modality
      assert_equal "consultation", result.session.mode
      assert_equal 3, result.session.scribe_outputs.count
      assert_equal %w[transcript form form], result.session.scribe_outputs.order(:id).map(&:output_type)
    end

    test "rejects an empty outputs array" do
      result = build(outputs: [])

      assert_not result.success?
      assert_nil result.session
      assert_equal "validation_error", result.error[:code]
      assert_equal "outputs must be a non-empty array", result.error[:message]
    end

    test "rejects an unknown output type" do
      result = build(outputs: [ { type: "summary" } ])

      assert_not result.success?
      assert_match "Invalid output type", result.error[:message]
    end

    test "rejects a form output carrying both page_id and fields" do
      result = build(outputs: [
        { type: "form", page_id: @page.id, fields: [ { key: "x", type: "string" } ] }
      ])

      assert_not result.success?
      assert_equal "form output needs exactly one of page_id or fields", result.error[:message]
    end

    test "rejects a form output carrying neither page_id nor fields" do
      result = build(outputs: [ { type: "form" } ])

      assert_not result.success?
      assert_equal "form output needs exactly one of page_id or fields", result.error[:message]
    end

    test "rejects a page belonging to another account" do
      foreign_page = create(:page, template: create(:template, account: create(:account)))

      result = build(outputs: [ { type: "form", page_id: foreign_page.id } ])

      assert_not result.success?
      # Same message as an absent page, so this is not an existence oracle.
      assert_match "does not reference an existing page", result.error[:message]
    end

    test "accepts a legacy template with no account" do
      legacy_page = create(:page, template: create(:template, account: nil))

      result = build(outputs: [ { type: "form", page_id: legacy_page.id } ])

      assert result.success?
      assert_equal legacy_page.id, result.session.scribe_outputs.sole.page_id
    end

    test "stores inline fields under inline_fields" do
      result = build(outputs: [
        { type: "form", fields: [ { key: "bp", label: "Blood pressure", type: "string" } ] }
      ])

      assert result.success?
      output = result.session.scribe_outputs.sole
      assert_nil output.page_id
      assert_equal [ { "key" => "bp", "label" => "Blood pressure", "type" => "string" } ], output.inline_fields
    end

    test "rejects inline fields with an unknown type" do
      result = build(outputs: [
        { type: "form", fields: [ { key: "bp", type: "blood_pressure" } ] }
      ])

      assert_not result.success?
      assert_match "invalid field type", result.error[:message]
    end

    test "records the caller's identity and request options" do
      user = create(:user, account: @account)

      result = build(
        outputs: [ { type: "transcript" } ],
        user: user,
        mode: "dictation",
        modality: "audio",
        language_hint: "hi",
        idempotency_key: "abc-123"
      )

      assert result.success?
      assert_equal user, result.session.user
      assert_equal "dictation", result.session.mode
      assert_equal "hi", result.session.language
      assert_equal "abc-123", result.session.idempotency_key
    end
  end
end
