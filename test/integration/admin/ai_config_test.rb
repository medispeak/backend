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

    test "non-admin users are redirected away from admin" do
      sign_out(@admin)
      plain_user = create(:user)
      sign_in(plain_user)

      get admin_ai_providers_path
      assert_response :redirect
    end
  end
end
