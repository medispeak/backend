require "test_helper"

# The audio endpoint is the one place this application hands out raw clinical
# recordings, so the things that must never regress are: signed-out access,
# tenant isolation, and the scoping that stops one session's id being used to
# read another session's blob.
class ScribeSessions::AudioControllerTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers

  setup do
    @user = create(:user)
    @session = create(:scribe_session, account: @user.account, user: @user, status: "completed")
    @session.audio_files.attach(io: StringIO.new("0123456789"), filename: "c.mp3", content_type: "audio/mpeg")
    @file = @session.audio_files_attachments.first

    @segment = @session.transcript_segments.create!(seq: 0, status: "done", content_type: "audio/wav")
    @segment.data.attach(io: StringIO.new("wavwavwav"), filename: "0.wav", content_type: "audio/wav")

    @other_user = create(:user)
    @other_session = create(:scribe_session, account: @other_user.account, user: @other_user)
    @other_session.audio_files.attach(io: StringIO.new("secret"), filename: "s.mp3", content_type: "audio/mpeg")
    @other_file = @other_session.audio_files_attachments.first
  end

  def audio_path(session, source, source_id, **params)
    scribe_session_audio_path(session, source: source, source_id: source_id, **params)
  end

  # --- Authentication --------------------------------------------------------

  test "redirects to sign in when signed out" do
    get audio_path(@session, "file", @file.id)
    assert_redirected_to new_user_session_path
  end

  # The test above passed while production answered 500 to exactly that request.
  # ActiveStorage::Streaming brings ActionController::Live, which runs the action
  # and its before_actions on a child thread; Warden signals "not signed in" by
  # `throw :warden`, caught by its middleware back on the request thread, so off
  # -thread the throw finds no catch and the redirect becomes an UncaughtThrowError.
  # The integration stack does not reproduce that, so this asserts the cause
  # instead of the symptom: this controller must never be a Live one.
  test "does not stream through ActionController::Live" do
    assert_not ScribeSessions::AudioController.include?(ActionController::Live),
               "ActionController::Live breaks Warden's redirect for signed-out requests"
    assert_not ScribeSessions::AudioController.include?(ActiveStorage::Streaming),
               "ActiveStorage::Streaming includes ActionController::Live"
  end

  test "answers an unsatisfiable range instead of raising" do
    sign_in @user
    get audio_path(@session, "file", @file.id), headers: { "Range" => "bytes=9999-99999" }

    assert_response :range_not_satisfiable
  end

  # A media element never asks for more than one range, and only one is honoured.
  test "refuses a multipart range" do
    sign_in @user
    get audio_path(@session, "file", @file.id), headers: { "Range" => "bytes=0-1,4-5" }

    assert_response :range_not_satisfiable
  end

  # Not a byte-range unit — Rack reports no ranges, and the whole file is the
  # right answer rather than a 416.
  test "ignores a range in units it does not understand" do
    sign_in @user
    get audio_path(@session, "file", @file.id), headers: { "Range" => "seconds=0-5" }

    assert_response :success
    assert_equal "0123456789", response.body
  end

  # --- Authorization ---------------------------------------------------------

  test "streams a stored audio file to its own account" do
    sign_in @user
    get audio_path(@session, "file", @file.id)

    assert_response :success
    assert_equal "audio/mpeg", response.media_type
    assert_equal "0123456789", response.body
  end

  test "streams a transcript segment" do
    sign_in @user
    get audio_path(@session, "segment", @segment.id)

    assert_response :success
    assert_equal "wavwavwav", response.body
  end

  test "another account cannot reach the audio" do
    sign_in @user
    get audio_path(@other_session, "file", @other_file.id)

    assert_redirected_to root_path
    assert_equal "You are not authorized to do that.", flash[:alert]
  end

  # Authorization is checked against the session in the URL, so the blob has to
  # be looked up THROUGH that session — otherwise a caller could name their own
  # session and someone else's attachment id.
  test "an attachment id belonging to another session is not found" do
    sign_in @user
    get audio_path(@session, "file", @other_file.id)

    assert_response :not_found
  end

  test "a segment id belonging to another session is not found" do
    other_segment = @other_session.transcript_segments.create!(seq: 0, status: "done")
    other_segment.data.attach(io: StringIO.new("x"), filename: "0.wav", content_type: "audio/wav")

    sign_in @user
    get audio_path(@session, "segment", other_segment.id)

    assert_response :not_found
  end

  test "an unknown part id is not found" do
    sign_in @user
    get audio_path(@session, "file", 0)

    assert_response :not_found
  end

  test "a segment with no attached audio is not found" do
    bare = @session.transcript_segments.create!(seq: 9, status: "pending")

    sign_in @user
    get audio_path(@session, "segment", bare.id)

    assert_response :not_found
  end

  # Raw chunks are not playable on their own, so there is deliberately no way to
  # ask for one.
  test "an unknown source does not route" do
    sign_in @user
    get "/scribe_sessions/#{@session.id}/audio/chunk/1"

    assert_response :not_found
  end

  # --- Serving ---------------------------------------------------------------

  # Seeking is made of range requests: a player jumping into the middle of a
  # recording must not have to pull everything before it.
  test "answers a range request with just that range" do
    sign_in @user
    get audio_path(@session, "file", @file.id), headers: { "Range" => "bytes=2-5" }

    assert_response :partial_content
    assert_equal "2345", response.body
    assert_equal "bytes 2-5/10", response.headers["Content-Range"]
  end

  # What a media element actually asks for first is the whole file as an open
  # -ended range, and a real consultation is megabytes rather than the ten bytes
  # the tests above use. Active Storage refuses a range wider than
  # streaming_chunk_max_size, so this pins the fact that a session-sized
  # recording stays under it — the failure mode otherwise is a 416 and a player
  # that never starts.
  test "serves an open-ended range over a realistically sized recording" do
    big = create(:scribe_session, account: @user.account, user: @user)
    bytes = "A" * 3.megabytes
    big.audio_files.attach(io: StringIO.new(bytes), filename: "long.mp3", content_type: "audio/mpeg")
    attachment = big.audio_files_attachments.first

    sign_in @user
    get audio_path(big, "file", attachment.id), headers: { "Range" => "bytes=0-" }

    assert_response :partial_content
    assert_equal "bytes 0-#{bytes.bytesize - 1}/#{bytes.bytesize}", response.headers["Content-Range"]
    assert_equal bytes.bytesize, response.body.bytesize
    assert_operator ScribeSession::MAX_AUDIO_BYTES, :<, ActiveStorage.streaming_chunk_max_size,
                    "a session at the upload cap must still fit in one streamed range"
  end

  test "advertises range support" do
    sign_in @user
    get audio_path(@session, "file", @file.id)

    assert_equal "bytes", response.headers["Accept-Ranges"]
  end

  # Clinical audio must not sit in a shared cache.
  test "caches privately and briefly" do
    sign_in @user
    get audio_path(@session, "file", @file.id)

    cache_control = response.headers["Cache-Control"]
    assert_includes cache_control, "private"
    assert_includes cache_control, "max-age=300"
    assert_not_includes cache_control, "public"
  end

  # Content-Disposition is a response header the URL author must not get to
  # write; Active Storage decides it from the blob and nothing here overrides it.
  test "the caller cannot dictate the content disposition" do
    sign_in @user
    get audio_path(@session, "file", @file.id, disposition: "attachment; filename=\"evil.html\"")

    assert_response :success
    assert_equal "attachment; filename=\"c.mp3\"; filename*=UTF-8''c.mp3",
                 response.headers["Content-Disposition"]
  end
end
