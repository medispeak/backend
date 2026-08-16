require "test_helper"

class PlaygroundControllerTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers

  setup do
    @user = create(:user)
    @account = @user.account

    @template = create(:template, account: @account, name: "Consultation note")
    @page = create(:page, template: @template, name: "History", prompt: "Summarise the history")
    @field = create(:form_field, page: @page, title: "chief_complaint",
                                 friendly_name: "Chief complaint", field_type: "string")

    @other_account = create(:account)
    @other_template = create(:template, account: @other_account, name: "Rival clinic template")
  end

  # --- authentication -------------------------------------------------------

  test "show redirects when signed out" do
    get template_playground_path(@template)
    assert_redirected_to new_user_session_path
  end

  test "create_session redirects when signed out" do
    post template_playground_sessions_path(@template)
    assert_redirected_to new_user_session_path
  end

  # --- tenancy --------------------------------------------------------------

  test "show refuses another account's template" do
    sign_in @user
    get template_playground_path(@other_template)
    assert_redirected_to root_path
    assert_equal "You are not authorized to do that.", flash[:alert]
  end

  test "create_session refuses another account's template" do
    sign_in @user
    assert_no_difference "ScribeSession.count" do
      post template_playground_sessions_path(@other_template)
    end
    assert_redirected_to root_path
  end

  test "show redirects for a template that does not exist" do
    sign_in @user
    get template_playground_path(id: 0, template_id: 0)
    assert_redirected_to templates_path
  end

  # --- show -----------------------------------------------------------------

  test "show renders the template's fields as empty rows" do
    sign_in @user
    get template_playground_path(@template)

    assert_response :success
    assert_select "[data-controller='playground']"
    assert_select "[data-field-key='chief_complaint']"
    assert_select "[data-field-key='chief_complaint']", text: /Chief complaint/
  end

  test "show offers nothing to run when the template has no fields" do
    sign_in @user
    empty = create(:template, account: @account, name: "Empty")
    create(:page, template: empty, name: "Blank")

    get template_playground_path(empty)

    assert_response :success
    assert_select "[data-controller='playground']", false
    assert_select "h3", text: /Nothing to fill in yet/
  end

  # --- create_session -------------------------------------------------------

  test "create_session builds one form output per page with fields" do
    sign_in @user
    second = create(:page, template: @template, name: "Examination")
    create(:form_field, page: second, title: "bp", friendly_name: "Blood pressure", field_type: "string")

    assert_difference "ScribeSession.count", 1 do
      post template_playground_sessions_path(@template)
    end

    assert_response :created
    body = JSON.parse(response.body)

    session = ScribeSession.find(body["session_id"])
    assert_equal @account, session.account
    assert_equal @user, session.user
    # No API token was involved: the browser is authorized by the Devise
    # session, and the scoped token is minted server-side.
    assert_nil session.api_token
    assert_equal "audio", session.modality
    assert_equal "auto", session.language

    assert_equal 2, session.scribe_outputs.count
    assert_equal [ "form", "form" ], session.scribe_outputs.map(&:output_type)
    assert_equal [ @page.id, second.id ].sort, session.scribe_outputs.map(&:page_id).sort
  end

  test "create_session returns a scoped token that verifies for this session" do
    sign_in @user
    post template_playground_sessions_path(@template)
    body = JSON.parse(response.body)

    assert body["token"].start_with?("mss_")
    claims = Scribe::SessionToken.verify(body["token"])
    assert_equal body["session_id"], claims["sid"]
    assert_equal Time.zone.parse(body["expires_at"]).to_i, Time.zone.parse(body["expires_at"]).to_i
  end

  test "create_session reports the field keys the model will fill" do
    sign_in @user
    post template_playground_sessions_path(@template)
    body = JSON.parse(response.body)

    page = body["pages"].sole
    assert_equal @page.id, page["id"]
    # `title` is the machine key the result comes back under; friendly_name is
    # only the label. Swapping them would silently break the fill.
    assert_equal [ { "key" => "chief_complaint", "label" => "Chief complaint" } ], page["fields"]
  end

  test "create_session skips pages that have no fields" do
    sign_in @user
    create(:page, template: @template, name: "Empty page")

    post template_playground_sessions_path(@template)
    session = ScribeSession.find(JSON.parse(response.body)["session_id"])

    assert_equal [ @page.id ], session.scribe_outputs.map(&:page_id)
  end

  test "create_session refuses a template with no fields at all" do
    sign_in @user
    empty = create(:template, account: @account, name: "Empty")
    create(:page, template: empty, name: "Blank")

    assert_no_difference "ScribeSession.count" do
      post template_playground_sessions_path(empty)
    end

    assert_response :unprocessable_entity
    assert_equal "validation_error", JSON.parse(response.body).dig("error", "code")
  end

  # --- mint_token -----------------------------------------------------------

  test "mint_token issues a fresh token for the account's own session" do
    sign_in @user
    post template_playground_sessions_path(@template)
    session_id = JSON.parse(response.body)["session_id"]

    post template_playground_session_token_path(@template, session_id: session_id)

    assert_response :success
    token = JSON.parse(response.body)["token"]
    assert_equal session_id, Scribe::SessionToken.verify(token)["sid"]
  end

  test "mint_token refuses a session belonging to another account" do
    sign_in @user
    foreign = ScribeSession.create!(account: @other_account, status: "created", expires_at: 1.hour.from_now)

    post template_playground_session_token_path(@template, session_id: foreign.id)

    assert_response :not_found
  end

  # --- result ---------------------------------------------------------------

  test "result renders the finished outputs through the consultation partial" do
    sign_in @user
    session = ScribeSession.create!(account: @account, user: @user, status: "completed",
                                    expires_at: 1.hour.from_now)
    session.scribe_outputs.create!(output_type: "form", status: "success", page: @page,
                                   result: { "chief_complaint" => "Headache for three days" })

    get template_playground_result_path(@template, session_id: session.id)

    assert_response :success
    assert_match "Headache for three days", response.body
    assert_select "p", text: /1\s+field filled/
    assert_select "a[href=?]", scribe_session_path(session), text: "View as consultation"
  end

  test "result refuses a session belonging to another account" do
    sign_in @user
    foreign = ScribeSession.create!(account: @other_account, status: "completed", expires_at: 1.hour.from_now)

    get template_playground_result_path(@template, session_id: foreign.id)

    assert_response :not_found
  end
end
