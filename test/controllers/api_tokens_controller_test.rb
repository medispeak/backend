require "test_helper"

class ApiTokensControllerTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers

  setup do
    @user = create(:user)
    @api_token = create(:api_token, user: @user, name: "Production server", expires_at: 30.days.from_now)

    # A user in a different account (User#ensure_account builds one per user).
    @other_user = create(:user)
    @other_token = create(:api_token, user: @other_user, name: "Someone else's key")
    # Prefixes are random hex, so pin this one: the leak assertions below have to
    # look for a string that cannot collide with the signed-in user's own key.
    @other_token.update_column(:token_prefix, "msk_live_ffff")
  end

  # --- authentication -------------------------------------------------------

  test "index redirects to sign in when signed out" do
    get api_tokens_path
    assert_redirected_to new_user_session_path
  end

  test "show redirects to sign in when signed out" do
    get api_token_path(@api_token)
    assert_redirected_to new_user_session_path
  end

  test "new redirects to sign in when signed out" do
    get new_api_token_path
    assert_redirected_to new_user_session_path
  end

  test "create redirects to sign in when signed out" do
    assert_no_difference "ApiToken.count" do
      post api_tokens_path, params: { api_token: { name: "Sneaky", expires_at: 30.days.from_now.iso8601 } }
    end
    assert_redirected_to new_user_session_path
  end

  test "destroy redirects to sign in when signed out" do
    delete api_token_path(@api_token)
    assert_redirected_to new_user_session_path
    assert @api_token.reload.active
  end

  # --- index ----------------------------------------------------------------

  test "index renders the signed in user's keys" do
    sign_in @user
    get api_tokens_path

    assert_response :success
    assert_includes response.body, "Production server"
    assert_includes response.body, @api_token.token_prefix
    assert_includes response.body, "Active"
  end

  test "index does not leak another account's keys" do
    sign_in @user
    get api_tokens_path

    assert_response :success
    assert_not_includes response.body, "Someone else's key"
    assert_not_includes response.body, @other_token.token_prefix
  end

  test "index renders an empty state when the user has no keys" do
    user_without_keys = create(:user)
    sign_in user_without_keys
    get api_tokens_path

    assert_response :success
    assert_includes response.body, "No API keys yet"
  end

  test "index renders a key whose expires_at is nil as expired, not active" do
    # The column is nullable; keys minted before expiry was required have none.
    # ApiToken.active filters on `expires_at > now`, which NULL never matches, so
    # such a key cannot authenticate and must not be advertised as usable.
    @api_token.update_column(:expires_at, nil)
    sign_in @user
    get api_tokens_path

    assert_response :success
    assert_includes response.body, "Not set"
    assert_not_includes response.body, "Does not expire"
    assert_includes response.body, "Expired"
    raw = @api_token.raw_token
    assert raw.present?, "the factory should expose the plaintext key"
    assert_nil ApiToken.authenticate(raw), "a key with no expiry must not authenticate"
  end

  test "index marks an aged out key as expired rather than active" do
    @api_token.update_column(:expires_at, 1.day.ago)
    sign_in @user
    get api_tokens_path

    assert_response :success
    assert_includes response.body, "Expired"
  end

  test "index marks a revoked key as revoked" do
    @api_token.update!(active: false)
    sign_in @user
    get api_tokens_path

    assert_response :success
    assert_includes response.body, "Revoked"
  end

  # --- show -----------------------------------------------------------------

  test "show renders the user's own key" do
    sign_in @user
    get api_token_path(@api_token)

    assert_response :success
    assert_includes response.body, "Production server"
    assert_includes response.body, @api_token.token_prefix
  end

  test "show renders a key whose expires_at is nil" do
    @api_token.update_column(:expires_at, nil)
    sign_in @user
    get api_token_path(@api_token)

    assert_response :success
    assert_includes response.body, "Not set"
    assert_not_includes response.body, "Does not expire"
  end

  test "show denies another account's key" do
    sign_in @user
    get api_token_path(@other_token)

    assert_response :redirect
    assert_equal "You are not authorized to do that.", flash[:alert]
  end

  # --- new / create ---------------------------------------------------------

  test "new renders the form" do
    sign_in @user
    get new_api_token_path

    assert_response :success
    assert_select "form[action=?]", api_tokens_path
    assert_select "input[name=?]", "api_token[name]"
    assert_select "select[name=?]", "api_token[expires_at]"
  end

  test "create mints a key for the current user and reveals it once" do
    sign_in @user

    assert_difference "ApiToken.count", 1 do
      post api_tokens_path, params: {
        api_token: { name: "Staging server", expires_at: 30.days.from_now.to_date.end_of_day.iso8601 }
      }
    end

    created = ApiToken.order(:id).last
    assert_equal @user, created.user
    assert_equal @user.account, created.account
    assert_equal "Staging server", created.name

    raw = flash[:raw_token]
    assert raw.present?, "the plaintext key should be handed to the next request"
    assert raw.start_with?(ApiToken::TOKEN_PREFIX)
    assert_redirected_to api_token_path(created)

    follow_redirect!
    assert_response :success
    assert_includes response.body, raw
    assert_includes response.body, "Copy your key now"

    # Reveal-once: a later visit must not show the plaintext key again.
    get api_token_path(created)
    assert_response :success
    assert_not_includes response.body, raw
    assert_not_includes response.body, "Copy your key now"
  end

  test "a flashed key is never revealed on a different key's page" do
    # If the redirect after create is lost (a second tab, a dropped response),
    # the flash rides into whatever request comes next. That must not print one
    # key's secret on another key's page.
    sign_in @user

    post api_tokens_path, params: {
      api_token: { name: "Staging server", expires_at: 30.days.from_now.to_date.end_of_day.iso8601 }
    }
    raw = flash[:raw_token]
    assert raw.present?

    get api_token_path(@api_token)
    assert_response :success
    assert_not_includes response.body, raw
    assert_not_includes response.body, "Copy your key now"
  end

  test "create re-renders the form when the name is blank" do
    sign_in @user

    assert_no_difference "ApiToken.count" do
      post api_tokens_path, params: {
        api_token: { name: "", expires_at: 30.days.from_now.to_date.end_of_day.iso8601 }
      }
    end

    assert_response :unprocessable_entity
    assert_select "input[name=?]", "api_token[name]"
  end

  test "create re-renders the form when the expiry is blank" do
    sign_in @user

    assert_no_difference "ApiToken.count" do
      post api_tokens_path, params: { api_token: { name: "No expiry", expires_at: "" } }
    end

    assert_response :unprocessable_entity
  end

  # --- destroy --------------------------------------------------------------

  test "destroy soft revokes the key rather than deleting it" do
    sign_in @user

    assert_no_difference "ApiToken.count" do
      delete api_token_path(@api_token)
    end

    assert_redirected_to api_tokens_path
    assert_not @api_token.reload.active
  end

  test "destroy revokes a legacy key that fails today's validations" do
    # name and expires_at became required after the table shipped. A revoke that
    # ran through validations would silently no-op on these rows while the flash
    # claimed success — leaving a live key the user believes is dead.
    @api_token.update_columns(expires_at: nil, name: nil)
    sign_in @user

    delete api_token_path(@api_token)

    assert_redirected_to api_tokens_path
    assert_equal "API key revoked.", flash[:notice]
    assert_not @api_token.reload.active
  end

  test "destroy denies another account's key" do
    sign_in @user

    delete api_token_path(@other_token)

    assert_response :redirect
    assert_equal "You are not authorized to do that.", flash[:alert]
    assert @other_token.reload.active
  end
end
