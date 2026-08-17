require "test_helper"

module Admin
  class AiConfigTest < ActionDispatch::IntegrationTest
    include Devise::Test::IntegrationHelpers

    setup do
      @admin = create(:user)
      @admin.update!(admin: true)
      sign_in(@admin)

      # Seed one of each so index/show pages render real rows.
      @provider = create(:ai_provider)
      @model = create(:ai_model, ai_provider: @provider)
      @assignment = create(:model_assignment, ai_model: @model)
      @account = create(:account)
      @usage_event = create(:usage_event, account: @account)
    end

    test "ai_providers index renders" do
      get admin_ai_providers_path
      assert_response :success
    end

    test "ai_providers new renders" do
      get new_admin_ai_provider_path
      assert_response :success
    end

    test "ai_providers show does not leak the api_key" do
      get admin_ai_provider_path(@provider)
      assert_response :success
      assert_not_includes response.body, @provider.api_key
    end

    test "ai_models index renders" do
      get admin_ai_models_path
      assert_response :success
    end

    # Configuring an assignment means finding the models that can serve one
    # function. Typed into the search box as `ocr:` / `asr:` / `structuring:`.
    test "ai_models index filters by the function a model can serve" do
      asr = create(:ai_model, ai_provider: @provider, display_name: "Whispery",
                              capabilities: { "accepts_audio" => true, "can_transcribe" => true })
      vision = create(:ai_model, ai_provider: @provider, display_name: "Seer",
                                 capabilities: { "supports_vision" => true })

      get admin_ai_models_path(search: "ocr:")
      assert_response :success
      assert_includes response.body, "Seer"
      assert_not_includes response.body, "Whispery"

      get admin_ai_models_path(search: "asr:")
      assert_response :success
      assert_includes response.body, "Whispery"
      assert_not_includes response.body, "Seer"
    end

    test "ai_models index names the functions each model can serve, readably" do
      create(:ai_model, ai_provider: @provider, display_name: "Dual",
                        capabilities: { "can_structure" => true, "supports_vision" => true })

      get admin_ai_models_path
      assert_response :success
      # The cell itself, not just the words appearing somewhere on the page —
      # and not a raw Ruby array, which is what Field::String renders for one.
      assert_includes response.body.gsub(/\s+/, " "), "structuring, ocr"
      assert_not_includes response.body, "[&quot;structuring&quot;"
    end

    test "model_assignments index renders" do
      get admin_model_assignments_path
      assert_response :success
    end

    test "accounts index renders" do
      get admin_accounts_path
      assert_response :success
    end

    test "accounts show renders" do
      get admin_account_path(@account)
      assert_response :success
    end

    test "usage_events index renders" do
      get admin_usage_events_path
      assert_response :success
    end

    test "usage_events show renders" do
      get admin_usage_event_path(@usage_event)
      assert_response :success
    end

    # ------------------------------------------------- jsonb round-trip
    # The admin form edits jsonb columns as raw JSON text. These replay the
    # exact requests from the 2026-08-16 incident, where "options"=>"{}"
    # (a String) was persisted as a JSON string scalar and broke every ASR
    # call in production.

    test "creating a model_assignment with options as JSON text stores a JSON object" do
      account = create(:account)

      post admin_model_assignments_path, params: {
        model_assignment: {
          scope_type: "Account", scope_id: account.id, function: "asr",
          ai_model_id: @model.id, fallback_ai_model_id: "", options: "{}"
        }
      }
      assert_response :redirect

      created = ModelAssignment.find_by!(scope_type: "Account", scope_id: account.id, function: "asr")
      assert_equal({}, created.options)
      assert_equal "object", jsonb_typeof("model_assignments", "options", created.id)
      assert_nothing_raised { Llm::ConfigResolver.call(function: :asr, account: account) }
    end

    test "updating a model_assignment with options as JSON text stores a JSON object" do
      patch admin_model_assignment_path(@assignment), params: {
        model_assignment: {
          scope_type: "System", scope_id: "", function: "asr",
          ai_model_id: @model.id, fallback_ai_model_id: "", options: '{"asr_mode": "translate"}'
        }
      }
      assert_response :redirect

      @assignment.reload
      assert_equal({ "asr_mode" => "translate" }, @assignment.options)
      assert_equal "object", jsonb_typeof("model_assignments", "options", @assignment.id)
      assert_equal :translate, Llm::ConfigResolver.call(function: :asr).asr_mode
    end

    test "updating a model_assignment with non-object JSON re-renders the form with an error" do
      patch admin_model_assignment_path(@assignment), params: {
        model_assignment: { options: "[1, 2]" }
      }
      assert_response :unprocessable_entity
      assert_includes response.body, "must be a JSON object"
      assert_equal({}, @assignment.reload.options)
    end

    test "model_assignment edit form renders options as valid JSON, not Ruby inspect" do
      @assignment.update!(options: { "asr_mode" => "translate" })

      get edit_admin_model_assignment_path(@assignment)
      assert_response :success
      assert_select "textarea[name='model_assignment[options]']" do |textarea|
        assert_equal({ "asr_mode" => "translate" }, JSON.parse(textarea.text))
      end
    end

    test "updating an ai_model with capabilities as JSON text stores a JSON object" do
      patch admin_ai_model_path(@model), params: {
        ai_model: { capabilities: '{"accepts_audio": true, "can_transcribe": true}' }
      }
      assert_response :redirect

      @model.reload
      assert_equal({ "accepts_audio" => true, "can_transcribe" => true }, @model.capabilities)
      assert_equal "object", jsonb_typeof("ai_models", "capabilities", @model.id)
      assert @model.capability?(:can_transcribe)
    end

    test "ai_model edit form renders capabilities as valid JSON" do
      get edit_admin_ai_model_path(@model)
      assert_response :success
      assert_select "textarea[name='ai_model[capabilities]']" do |textarea|
        assert_equal @model.capabilities, JSON.parse(textarea.text)
      end
    end

    test "non-admin users are redirected away from admin" do
      sign_out(@admin)
      plain_user = create(:user)
      sign_in(plain_user)

      get admin_ai_providers_path
      assert_response :redirect
    end

    private

    def jsonb_typeof(table, column, id)
      ActiveRecord::Base.connection.select_value(
        "SELECT jsonb_typeof(#{column}) FROM #{table} WHERE id = #{id.to_i}"
      )
    end
  end
end
