require "application_system_test_case"

# The playground is the app's only microphone-driven surface, and the riskiest
# part of it — a vendored WebAssembly VAD loading under the app's CSP, against a
# real getUserMedia — cannot be verified any other way. These tests drive a real
# headless Chrome with a synthetic microphone.
#
# They stop at "recording has started". Going further would mean stubbing a
# provider for ASR and settling background jobs, which the integration and
# service suites already cover without a browser.
class PlaygroundTest < ApplicationSystemTestCase
  # Sign in through Warden rather than the sign-in form: driving the form makes
  # every test here depend on a CSRF token surviving Turbo's page cache across
  # examples, which is a failure mode that has nothing to do with the recorder.
  include Warden::Test::Helpers

  setup do
    Warden.test_mode!
    @user = create(:user)
    @account = @user.account

    @template = create(:template, account: @account, name: "Consultation note")
    @page = create(:page, template: @template, name: "History")
    create(:form_field, page: @page, title: "chief_complaint",
                        friendly_name: "Chief complaint", field_type: "string")

    login_as @user, scope: :user
  end

  teardown { Warden.test_reset! }

  test "the template page offers a way to try it" do
    visit template_path(@template)
    assert_link "Try it"

    click_on "Try it"
    assert_selector "h1", text: "Try #{@template.name}"
  end

  test "fields are listed as empty rows waiting to fill" do
    visit template_playground_path(@template)

    # Case-insensitive: the label is upper-cased in CSS, so the rendered text
    # Capybara sees is "CHIEF COMPLAINT".
    assert_selector "[data-field-key='chief_complaint']", text: /chief complaint/i
    assert_selector "[data-field-key='chief_complaint'] .pg-field-value", text: "—"
    assert_selector "button[aria-label='Start recording']"
  end

  test "pressing record loads the VAD, opens the mic and starts a session" do
    visit template_playground_path(@template)

    assert_difference -> { ScribeSession.count }, 1 do
      find("button[aria-label='Start recording']").click

      # Loading ~12MB of vendored wasm and acquiring the mic is genuinely slow
      # on a cold cache, so this waits well past Capybara's default.
      assert_selector "button[aria-label='Stop recording']", wait: 30
    end

    assert_text "Listening"
    assert_selector ".pg-orb-recording"
    assert_selector "[data-playground-target='timer']", visible: true

    # The run was declared against the template's page, exactly as a production
    # integration would declare it.
    session = ScribeSession.order(:id).last
    assert_equal @account, session.account
    assert_equal @user, session.user
    assert_equal [ @page.id ], session.scribe_outputs.map(&:page_id)

    # No CSP violation: onnxruntime compiled its wasm, which a bare
    # `script_src :self` would have blocked.
    assert page.evaluate_script("typeof window.vad !== 'undefined'")
  end
end
