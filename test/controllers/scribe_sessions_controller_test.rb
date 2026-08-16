require "test_helper"

# Consultations are the account's clinical record, so the three things that
# must never regress are: signed-out access, tenant isolation, and the show
# page rendering a fully-populated session without a 500.
class ScribeSessionsControllerTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers

  setup do
    @user = create(:user)
    @account = @user.account
    @session = create(:scribe_session, account: @account, user: @user, status: "completed")

    # A second account, created through its own user so the tenancy boundary is
    # the real one the policy scope enforces.
    @other_user = create(:user)
    @other_session = create(:scribe_session, account: @other_user.account, user: @other_user)
  end

  # --- Authentication --------------------------------------------------------

  test "index redirects to sign in when signed out" do
    get scribe_sessions_path
    assert_redirected_to new_user_session_path
  end

  test "show redirects to sign in when signed out" do
    get scribe_session_path(@session)
    assert_redirected_to new_user_session_path
  end

  # --- Index -----------------------------------------------------------------

  test "index renders the account's sessions" do
    sign_in @user
    get scribe_sessions_path

    assert_response :success
    assert_select "a[href=?]", scribe_session_path(@session)
  end

  test "index does not leak another account's sessions" do
    sign_in @user
    get scribe_sessions_path

    assert_response :success
    assert_select "a[href=?]", scribe_session_path(@other_session), count: 0
  end

  test "index shows an empty state when the account has no sessions" do
    @session.destroy!
    sign_in @user
    get scribe_sessions_path

    assert_response :success
    assert_match "No consultations yet", response.body
  end

  test "index filters by status" do
    processing = create(:scribe_session, account: @account, user: @user, status: "processing")

    sign_in @user
    get scribe_sessions_path(status: "processing")

    assert_response :success
    assert_select "a[href=?]", scribe_session_path(processing)
    assert_select "a[href=?]", scribe_session_path(@session), count: 0
  end

  test "index filters by modality" do
    document = create(:scribe_session, account: @account, user: @user, modality: "document")

    sign_in @user
    get scribe_sessions_path(modality: "document")

    assert_response :success
    assert_select "a[href=?]", scribe_session_path(document)
    assert_select "a[href=?]", scribe_session_path(@session), count: 0
  end

  # An unknown filter must be ignored rather than 500 or reach the query.
  test "index ignores a status outside the enum" do
    sign_in @user
    get scribe_sessions_path(status: "'; DROP TABLE scribe_sessions; --")

    assert_response :success
    assert_select "a[href=?]", scribe_session_path(@session)
  end

  test "index ignores a modality outside the enum" do
    sign_in @user
    get scribe_sessions_path(modality: "telepathy")

    assert_response :success
    assert_select "a[href=?]", scribe_session_path(@session)
  end

  # Pagy raises instead of clamping, so a stale link (?page=4 after the list
  # shrank) or a junk value must land on a real page, not on a 500.
  test "index clamps a page past the end" do
    sign_in @user
    get scribe_sessions_path(page: 99)

    assert_response :success
    assert_select "a[href=?]", scribe_session_path(@session)
  end

  test "index survives a non-numeric page" do
    sign_in @user
    get scribe_sessions_path(page: "abc")

    assert_response :success
    assert_select "a[href=?]", scribe_session_path(@session)
  end

  # Money must agree with the rest of the app: Usage, the dashboard and the v2
  # API all count finalized events only. A pending event is a reservation that
  # is recomputed on settlement; a failed one is never charged.
  test "index costs count settled usage events only" do
    create(:usage_event, account: @account, scribe_session: @session, status: "finalized", cost: 0.5)
    create(:usage_event, account: @account, scribe_session: @session, status: "pending", cost: 9.0)
    create(:usage_event, account: @account, scribe_session: @session, status: "failed", cost: 9.0)

    sign_in @user
    get scribe_sessions_path

    assert_response :success
    assert_match "$0.50", response.body
    assert_no_match(/\$18\.50|\$9\.50/, response.body)
  end

  # --- Show ------------------------------------------------------------------

  test "show renders a session with transcript, outputs and usage" do
    create(:transcript, scribe_session: @session, text: "Patient reports a mild headache.")
    @session.scribe_outputs.create!(
      output_type: "form",
      status: "success",
      result: { "chief_complaint" => "Headache", "severity" => 3, "red_flags" => [ "None" ] }
    )
    create(:usage_event, account: @account, user: @user, scribe_session: @session,
                         function: "asr", total_tokens: 120, cost: 0.004321)

    sign_in @user
    get scribe_session_path(@session)

    assert_response :success
    assert_match "Patient reports a mild headache.", response.body
    assert_match "Chief complaint", response.body
    assert_match "Headache", response.body
    assert_match "Pipeline", response.body
  end

  test "show renders a session with no transcript and no outputs" do
    sign_in @user
    get scribe_session_path(@session)

    assert_response :success
    assert_match "No transcript yet", response.body
  end

  test "show renders result errors for a partial output" do
    create(:transcript, scribe_session: @session)
    @session.scribe_outputs.create!(
      output_type: "form",
      status: "partial",
      result: { "severity" => nil },
      result_errors: [ { "pointer" => "/severity", "message" => "value is not a number" } ]
    )

    sign_in @user
    get scribe_session_path(@session)

    assert_response :success
    assert_match "value is not a number", response.body
  end

  test "show renders a note output as prose" do
    create(:transcript, scribe_session: @session)
    @session.scribe_outputs.create!(
      output_type: "note",
      status: "success",
      result: { "note" => "Subjective: headache for two days." }
    )

    sign_in @user
    get scribe_session_path(@session)

    assert_response :success
    assert_match "Subjective: headache for two days.", response.body
  end

  # Expiry closes the session to further capture; it deletes nothing, so the
  # notice must not claim the media was purged.
  test "show notes that the session has expired" do
    @session.update!(expires_at: 1.hour.ago)

    sign_in @user
    get scribe_session_path(@session)

    assert_response :success
    assert_match "expired on", response.body
    assert_match "no longer be committed", response.body
    assert_no_match(/no longer stored/, response.body)
  end

  # --- Recording -------------------------------------------------------------

  test "show offers a player for a stored recording" do
    @session.audio_files.attach(io: StringIO.new("audio"), filename: "c.mp3", content_type: "audio/mpeg")
    file = @session.audio_files_attachments.first

    sign_in @user
    get scribe_session_path(@session)

    assert_response :success
    assert_match "Recording", response.body
    assert_select "[data-controller=audio-player]"
    assert_select "audio[src=?]", scribe_session_audio_path(@session, source: "file", source_id: file.id)
  end

  # The streaming path's clips are timed and transcribed, which is what makes
  # the transcript usable as an index into the audio.
  test "show lists the speech segments as seek points" do
    %w[first second].each_with_index do |text, seq|
      segment = @session.transcript_segments.create!(seq: seq, status: "done", duration_seconds: 3.0, text: text)
      segment.data.attach(io: StringIO.new("wav"), filename: "#{seq}.wav", content_type: "audio/wav")
    end

    sign_in @user
    get scribe_session_path(@session)

    assert_response :success
    assert_match "2 speech segments", response.body
    assert_select "button.ap-row", count: 2
    # 3s + 3s, printed as media time rather than as a measured quantity.
    assert_match "0:06", response.body
  end

  test "show has no player when nothing was recorded" do
    sign_in @user
    get scribe_session_path(@session)

    assert_response :success
    assert_select "[data-controller=audio-player]", count: 0
  end

  # A document session has text, never speech.
  test "show has no player for an uploaded document" do
    document = create(:scribe_session, account: @account, user: @user, modality: "document")
    document.document_files.attach(io: StringIO.new("%PDF-"), filename: "labs.pdf", content_type: "application/pdf")

    sign_in @user
    get scribe_session_path(document)

    assert_response :success
    assert_select "[data-controller=audio-player]", count: 0
  end

  test "show denies another account's session" do
    sign_in @user
    get scribe_session_path(@other_session)

    assert_redirected_to root_path
    assert_equal "You are not authorized to do that.", flash[:alert]
  end

  test "an admin may open any account's session" do
    admin = create(:user)
    admin.update!(admin: true)

    sign_in admin
    get scribe_session_path(@other_session)

    assert_response :success
  end
end
