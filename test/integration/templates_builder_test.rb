require "test_helper"

class TemplatesBuilderTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers

  setup do
    @user = create(:user)
    sign_in @user
    provider = create(:ai_provider)
    @asr_model = create(:ai_model, ai_provider: provider, api_model_id: "whisper-1",
                                   capabilities: { "can_transcribe" => true })
    @structuring_model = create(:ai_model, ai_provider: provider, api_model_id: "gpt-4o-mini",
                                           capabilities: { "can_structure" => true })
  end

  test "new renders the builder" do
    get new_template_path
    assert_response :success
    assert_select "form"
  end

  test "creates a template with nested pages, fields, and model assignments" do
    assert_difference [ "Template.count", "Page.count", "FormField.count" ], 1 do
      post templates_path, params: {
        template: {
          name: "Consultation", description: "A consultation form",
          pages_attributes: {
            "0" => {
              name: "History", prompt: "Fill the history",
              form_fields_attributes: {
                "0" => { title: "complaint", friendly_name: "Complaint", field_type: "string" }
              }
            }
          }
        },
        asr_ai_model_id: @asr_model.id,
        structuring_ai_model_id: @structuring_model.id
      }
    end

    template = Template.last
    assert_redirected_to template_path(template)
    assert_equal "History", template.pages.first.name
    assert_equal "complaint", template.pages.first.form_fields.first.title

    assert_equal @asr_model.id,
                 ModelAssignment.find_by(scope_type: "Template", scope_id: template.id, function: "asr").ai_model_id
    assert_equal @structuring_model.id,
                 ModelAssignment.find_by(scope_type: "Template", scope_id: template.id, function: "structuring").ai_model_id
  end

  test "blank pages are rejected" do
    assert_no_difference "Page.count" do
      post templates_path, params: {
        template: {
          name: "Empty", description: "no pages",
          pages_attributes: { "0" => { name: "" } }
        }
      }
    end
    assert_redirected_to template_path(Template.last)
  end

  test "requires authentication" do
    sign_out @user
    get new_template_path
    assert_response :redirect
  end
end
