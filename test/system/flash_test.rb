require "application_system_test_case"

# Flash messages are dismissible (issue #76). The dismiss button is pure
# client-side behaviour — a Stimulus action that removes the enclosing
# `.notice` — so it cannot be covered anywhere but a real browser.
#
# The control is an icon button carrying only `aria-label="Dismiss"`, which
# Capybara does not match from `click_button` unless enable_aria_label is set,
# hence the explicit selector below.
class FlashTest < ApplicationSystemTestCase
  include Warden::Test::Helpers

  DISMISS = "#flash button[aria-label='Dismiss']".freeze

  setup do
    Warden.test_mode!
    @user = create(:user)
    login_as @user, scope: :user
  end

  teardown { Warden.test_reset! }

  # Visiting another account's template redirects to root with an alert — a
  # real flash raised by the app, not one staged for the test.
  def trigger_alert
    other = create(:template, account: create(:account), name: "Someone else's")
    visit template_playground_path(other)
  end

  test "an alert can be dismissed without reloading the page" do
    trigger_alert
    assert_text "You are not authorized to do that."
    assert_selector "#flash .notice"

    find(DISMISS).click

    assert_no_selector "#flash .notice"
    assert_no_text "You are not authorized to do that."
    # Dismissed in the browser, not by navigating away: the URL must not move.
    assert_equal root_path, URI.parse(page.current_url).path
  end

  test "the dismiss control is labelled for assistive tech and cannot submit a form" do
    trigger_alert
    assert_selector "#flash button[type='button'][aria-label='Dismiss']"
  end

  test "a notice raised by signing in is dismissible too" do
    Warden.test_reset!
    visit new_user_session_path
    fill_in "Email", with: @user.email
    fill_in "Password", with: "password123"
    click_button "Log in"

    assert_selector "#flash .notice"
    find(DISMISS).click
    assert_no_selector "#flash .notice"
  end
end
