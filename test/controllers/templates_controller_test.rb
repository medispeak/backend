require "test_helper"

class TemplatesControllerTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers

  setup do
    @user = create(:user)
    @account = @user.account

    @template = create(:template, account: @account, name: "Consultation note")
    @page = create(:page, template: @template, name: "History", prompt: "Summarise the history")
    @field = create(:form_field, page: @page, title: "chief_complaint",
                                 friendly_name: "Chief complaint", field_type: "string")

    @other_template = create(:template, account: create(:account), name: "Rival clinic template")
  end

  # --- authentication -------------------------------------------------------

  test "index redirects when signed out" do
    get templates_path
    assert_redirected_to new_user_session_path
  end

  test "show redirects when signed out" do
    get template_path(@template)
    assert_redirected_to new_user_session_path
  end

  test "new redirects when signed out" do
    get new_template_path
    assert_redirected_to new_user_session_path
  end

  # --- index ----------------------------------------------------------------

  test "index lists the account's templates" do
    sign_in @user
    get templates_path

    assert_response :success
    assert_select "a", text: "Consultation note"
    assert_select "a[href=?]", new_template_path
  end

  test "index does not leak another account's templates" do
    sign_in @user
    get templates_path

    assert_response :success
    assert_no_match "Rival clinic template", response.body
  end

  test "index accepts the supported sort columns" do
    sign_in @user

    get templates_path(sort: "name", direction: "asc")
    assert_response :success

    get templates_path(sort: "created_at", direction: "desc")
    assert_response :success
  end

  test "index ignores an unsupported sort column" do
    sign_in @user
    get templates_path(sort: "account_id", direction: "asc")

    assert_response :success
  end

  # Pagy raises (OverflowError / VariableError) rather than clamping, so a stale
  # bookmark or a hand-edited page number used to render a 500.
  test "index survives an out-of-range page" do
    sign_in @user
    get templates_path(page: 99)

    assert_response :success
  end

  test "index survives a non-numeric page" do
    sign_in @user
    get templates_path(page: "notanumber")

    assert_response :success
  end

  # --- show -----------------------------------------------------------------

  test "show renders the template with its pages and fields" do
    sign_in @user
    get template_path(@template)

    assert_response :success
    assert_select "h1", text: "Consultation note"
    assert_match "History", response.body
    assert_match "Chief complaint", response.body
    assert_match "chief_complaint", response.body
  end

  test "show exposes edit and delete actions" do
    sign_in @user
    get template_path(@template)

    assert_response :success
    assert_select "a[href=?]", edit_template_path(@template)
    assert_select "form[action=?]", template_path(@template)
  end

  test "show denies another account's template" do
    sign_in @user
    get template_path(@other_template)

    assert_redirected_to root_path
    assert_equal "You are not authorized to do that.", flash[:alert]
  end

  test "show redirects to the index for a missing template" do
    sign_in @user
    get template_path(id: 0)

    assert_redirected_to templates_path
  end

  # --- new / create ---------------------------------------------------------

  test "new renders the builder" do
    sign_in @user
    get new_template_path

    assert_response :success
    assert_select "form"
  end

  test "create stores the template on the current account" do
    sign_in @user

    assert_difference "Template.count", 1 do
      post templates_path, params: {
        template: {
          name: "Discharge summary", description: "Summary at discharge",
          pages_attributes: {
            "0" => {
              name: "Summary",
              form_fields_attributes: {
                "0" => { title: "diagnosis", friendly_name: "Diagnosis", field_type: "string" }
              }
            }
          }
        }
      }
    end

    template = Template.order(:created_at).last
    assert_redirected_to template_path(template)
    assert_equal @account.id, template.account_id
    assert_equal "diagnosis", template.pages.first.form_fields.first.title
  end

  test "create re-renders the builder when invalid" do
    sign_in @user

    assert_no_difference "Template.count" do
      post templates_path, params: { template: { name: "", description: "" } }
    end
    assert_response :unprocessable_entity
  end

  # --- edit / update --------------------------------------------------------

  test "edit renders for an owned template" do
    sign_in @user
    get edit_template_path(@template)

    assert_response :success
    assert_select "form"
  end

  test "edit denies another account's template" do
    sign_in @user
    get edit_template_path(@other_template)

    assert_redirected_to root_path
  end

  test "update saves changes to an owned template" do
    sign_in @user
    patch template_path(@template), params: { template: { name: "Renamed note" } }

    assert_redirected_to template_path(@template)
    assert_equal "Renamed note", @template.reload.name
  end

  test "update denies another account's template" do
    sign_in @user
    patch template_path(@other_template), params: { template: { name: "Hijacked" } }

    assert_redirected_to root_path
    assert_equal "Rival clinic template", @other_template.reload.name
  end

  # --- destroy --------------------------------------------------------------

  test "destroy removes an owned template" do
    sign_in @user

    assert_difference "Template.count", -1 do
      delete template_path(@template)
    end
    assert_response :see_other
    assert_redirected_to templates_path
  end

  # ModelAssignment keys off (scope_type, scope_id), so neither the template's
  # own rows nor its pages' rows are cascaded by the association.
  test "destroy clears the template and page model assignments" do
    sign_in @user
    model = create(:ai_model)
    create(:model_assignment, scope_type: "Template", scope_id: @template.id,
                              function: "asr", ai_model: model)
    create(:model_assignment, scope_type: "Page", scope_id: @page.id,
                              function: "structuring", ai_model: model)

    assert_difference "ModelAssignment.count", -2 do
      delete template_path(@template)
    end
  end

  test "destroy denies another account's template" do
    sign_in @user

    assert_no_difference "Template.count" do
      delete template_path(@other_template)
    end
    assert_redirected_to root_path
  end
end
