require "test_helper"

module Admin
  # Renders the read-only scribe admin: a session and ALL data associated with
  # it (transcript, outputs, segments, chunks, metering). A 200 proves the
  # Administrate dashboards + association fields render without a 500.
  class ScribeSessionsTest < ActionDispatch::IntegrationTest
    include Devise::Test::IntegrationHelpers

    setup do
      @admin = create(:user)
      @admin.update!(admin: true)
      sign_in(@admin)

      @session = create(:scribe_session, account: @admin.account, user: @admin)
      @transcript = Transcript.create!(
        scribe_session: @session, text: "patient has a headache",
        language: "en", provider: "openai", model: "whisper-1", duration_seconds: 4.2
      )
      @output = @session.scribe_outputs.create!(
        output_type: "form", status: "success",
        result: { "complaint" => "headache" },
        inline_fields: [ { "key" => "complaint", "label" => "Complaint", "type" => "string" } ]
      )
      @segment = @session.transcript_segments.create!(
        seq: 0, status: "done", text: "patient has a headache",
        language: "en", provider: "openai", model: "whisper-1", duration_seconds: 2.0
      )
      @chunk = @session.audio_chunks.create!(seq: 0, content_type: "audio/webm")
      @usage = create(:usage_event, account: @admin.account, scribe_session: @session)
    end

    test "scribe_sessions index renders" do
      get admin_scribe_sessions_path
      assert_response :success
    end

    test "scribe_session show renders with all associated data" do
      get admin_scribe_session_path(@session)
      assert_response :success
      assert_includes response.body, "patient has a headache",
                       "the transcript text should be visible on the session show page"
    end

    test "every child index page renders" do
      [
        admin_scribe_outputs_path,
        admin_transcripts_path,
        admin_scribe_transcript_segments_path,
        admin_scribe_audio_chunks_path
      ].each do |path|
        get path
        assert_response :success, "index #{path} did not render"
      end
    end

    test "every child show page renders" do
      get admin_scribe_output_path(@output)
      assert_response :success
      get admin_transcript_path(@transcript)
      assert_response :success
      get admin_scribe_transcript_segment_path(@segment)
      assert_response :success
      get admin_scribe_audio_chunk_path(@chunk)
      assert_response :success
    end

    test "read-only: no create/edit routes are defined for scribe sessions" do
      assert_not respond_to?(:new_admin_scribe_session_path),
                 "scribe sessions must be inspection-only (no new/edit routes)"
    end
  end
end
