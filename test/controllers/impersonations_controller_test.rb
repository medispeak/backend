require "test_helper"

# Admin "view as user". The properties worth pinning down are the ones that are
# invisible when they break: that /admin really closes, that writes really are
# refused, and that the admin can always get back out.
class ImpersonationsControllerTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers

  setup do
    @admin = create(:user)
    @admin.update!(admin: true, email: "admin@example.com")

    @target = create(:user)
    @target.update!(email: "clinician@example.com")
    @target_account = @target.account
    @target_account.update!(name: "Riverside Clinic")
  end

  def start_impersonating(user = @target)
    post impersonate_admin_user_path(user)
  end

  # ------------------------------------------------------------- who may start

  test "signed-out visitor cannot start an impersonation" do
    start_impersonating
    assert_redirected_to new_user_session_path
  end

  test "non-admin cannot start an impersonation" do
    sign_in @target
    other = create(:user)
    post impersonate_admin_user_path(other)
    assert_redirected_to root_path
    follow_redirect!
    # Still themselves, not the user they aimed at.
    assert_match @target.account.name, response.body
  end

  test "admin cannot impersonate another admin" do
    second_admin = create(:user)
    second_admin.update!(admin: true, email: "other-admin@example.com")

    sign_in @admin
    post impersonate_admin_user_path(second_admin)

    assert_redirected_to admin_user_path(second_admin)
    assert_equal "Cannot view as another admin.", flash[:alert]

    # And no impersonation was started: /admin is still reachable.
    get admin_users_path
    assert_response :success
  end

  # ------------------------------------------------------------ the entry point

  # The show override renders Administrate's own template rather than a copy of
  # it, so this guards both halves: that the button appears, and that the stock
  # page still renders around it.
  test "admin user page offers the button and still renders the resource" do
    sign_in @admin
    get admin_user_path(@target)

    assert_response :success
    assert_match "View as user", response.body
    assert_match impersonate_admin_user_path(@target), response.body
    assert_match "clinician@example.com", response.body
  end

  test "admin user page hides the button for another admin" do
    second_admin = create(:user)
    second_admin.update!(admin: true, email: "other-admin@example.com")

    sign_in @admin
    get admin_user_path(second_admin)

    assert_response :success
    assert_no_match "View as user", response.body
  end

  # ------------------------------------------------------------- the happy path

  test "admin starts impersonating and sees the target's account" do
    sign_in @admin
    start_impersonating

    assert_redirected_to root_path
    assert_equal "Now viewing as clinician@example.com.", flash[:notice]

    get account_path
    assert_response :success
    assert_match "Riverside Clinic", response.body
  end

  test "banner names both identities while impersonating" do
    sign_in @admin
    start_impersonating

    get root_path
    assert_response :success
    assert_match "clinician@example.com", response.body
    assert_match "admin@example.com", response.body
  end

  test "no banner when not impersonating" do
    sign_in @target
    get root_path
    assert_response :success
    assert_no_match(/Stop viewing as user/, response.body)
  end

  # The exit control sits under a fixed z-50 flash toast by default, which hid
  # it exactly when a read-only refusal fired. The banner outranks the flash and
  # the flash drops below it; both have to hold or the safety valve is covered.
  test "banner outranks the flash and the flash steps aside for it" do
    sign_in @admin
    start_impersonating

    get root_path
    assert_match "sticky top-0 z-[60]", response.body
    assert_match 'id="flash" class="fixed top-16', response.body
  end

  test "flash sits at its normal offset when not impersonating" do
    sign_in @target
    get root_path
    assert_match 'id="flash" class="fixed top-4', response.body
  end

  # --------------------------------------------------------- powers are dropped

  test "admin namespace closes while impersonating" do
    sign_in @admin
    get admin_users_path
    assert_response :success, "precondition: admin can reach /admin"

    start_impersonating
    get admin_users_path

    assert_redirected_to root_path
    assert_equal "Not authorized.", flash[:alert]
  end

  # ------------------------------------------------------------- read-only rule

  test "writes are refused while impersonating" do
    sign_in @admin
    start_impersonating

    patch account_path, params: { account: { name: "Renamed By Admin" } }

    assert_redirected_to root_path
    assert_match(/read-only/, flash[:alert])
    assert_equal "Riverside Clinic", @target_account.reload.name
  end

  test "reads are unaffected while impersonating" do
    sign_in @admin
    start_impersonating

    get account_path
    assert_response :success
  end

  test "the same write succeeds once impersonation has stopped" do
    sign_in @target
    patch account_path, params: { account: { name: "Renamed By Owner" } }
    assert_equal "Renamed By Owner", @target_account.reload.name
  end

  # ----------------------------------------------------------------- getting out

  test "stopping restores the admin and returns them to the user's admin page" do
    sign_in @admin
    start_impersonating

    delete impersonation_path

    assert_redirected_to admin_user_path(@target)
    assert_equal "Stopped viewing as clinician@example.com.", flash[:notice]

    # Powers are back.
    get admin_users_path
    assert_response :success
  end

  # The exit must not sit behind the read-only guard or the admin-only gate,
  # or it becomes unreachable exactly when it is needed.
  test "the exit is reachable despite being a write and despite /admin being closed" do
    sign_in @admin
    start_impersonating

    get admin_users_path
    assert_redirected_to root_path, "precondition: /admin is closed"

    delete impersonation_path
    assert_redirected_to admin_user_path(@target)
  end

  test "stopping when not impersonating is a harmless no-op" do
    sign_in @admin
    delete impersonation_path
    assert_redirected_to root_path
  end

  # pretender re-checks the real login each request, so a logout cannot leave a
  # dangling impersonated session behind.
  test "signing out ends the impersonation" do
    sign_in @admin
    start_impersonating
    sign_out @admin

    get account_path
    assert_redirected_to new_user_session_path
  end
end
