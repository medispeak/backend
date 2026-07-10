require "test_helper"
require "mocha/minitest"

module Api
  module V2
    # Exercises the incremental per-segment transcription path (plan 022)
    # end-to-end through the browser credential: standalone transcription
    # segments are transcribed on arrival by TranscribeSegmentJob (run inline by
    # the test :inline ActiveJob adapter), the live transcript grows during
    # recording, and commit assembles the final transcript from the ordered
    # segment texts with no whole-file ASR re-download in the happy path.
    class AudioSegmentsTest < ActionDispatch::IntegrationTest
      setup do
        Rails.cache.clear if Rails.cache.respond_to?(:clear)

        @account = create(:account)
        @user = create(:user, account: @account)
        @token = create(:api_token, user: @user, account: @account)
        @account_headers = { "Authorization" => "Bearer #{@token.raw_token}" }

        @session = create(:scribe_session, account: @account, api_token: @token, user: @user)
        @session_token, = Scribe::SessionToken.mint(@session)
        @auth = { "Authorization" => "Bearer #{@session_token}" }

        @prev_openai_token = ENV["OPENAI_ACCESS_TOKEN"]
        ENV["OPENAI_ACCESS_TOKEN"] = "test-key"
        stub_openai!

        # The incremental path is OFF by default; enable it for these tests. The
        # flag-off test re-stubs this to false.
        Scribe::Incremental.stubs(:enabled?).returns(true)
      end

      teardown do
        Rails.cache.clear if Rails.cache.respond_to?(:clear)
        ENV["OPENAI_ACCESS_TOKEN"] = @prev_openai_token
      end

      test "two segments assemble into the committed transcript with no extra whole-file ASR call" do
        post segments_url, params: { seq: 0, segment: segment_upload("seg-zero") }, headers: @auth
        assert_response :ok
        assert_equal 0, JSON.parse(response.body)["received"]
        seg0 = @session.transcript_segments.find_by(seq: 0)
        assert_equal "done", seg0.status, "the inline job must transcribe the segment on arrival"
        assert seg0.text.present?

        # Live transcript is exposed the instant the first segment finishes ASR.
        get show_url, headers: @auth
        assert_response :accepted
        live_after0 = JSON.parse(response.body).dig("transcript", "text")
        assert live_after0.present?, "live transcript should be non-empty after seq 0"

        post segments_url, params: { seq: 1, segment: segment_upload("seg-one") }, headers: @auth
        assert_response :ok
        seg1 = @session.transcript_segments.find_by(seq: 1)
        assert_equal "done", seg1.status

        get show_url, headers: @auth
        live_after1 = JSON.parse(response.body).dig("transcript", "text")
        assert live_after1.length > live_after0.length, "live transcript should grow after seq 1"

        # The continuous STORAGE recording is always uploaded too (segments are an
        # ASR overlay, not a substitute), so the commit audio guard is satisfied.
        post audio_url, params: { audio: single_shot_upload("full-storage-audio") }, headers: @auth
        assert_response :ok

        post commit_url, headers: @auth
        assert_response :accepted

        @session.reload
        assert_equal "completed", @session.status
        expected = [ seg0.reload.text, seg1.reload.text ].join(" ")
        assert_equal expected, @session.transcript.text,
                     "committed transcript must equal the ordered segment texts joined with a space"

        # ASR ran once per segment and NOT a third time at commit (all done).
        assert_requested :post, %r{/v1/audio/transcriptions}, times: 2
      end

      test "re-POSTing a seq is idempotent and never re-transcribes; re-commit runs no ASR" do
        post segments_url, params: { seq: 0, segment: segment_upload("seg-zero") }, headers: @auth
        assert_response :ok
        post segments_url, params: { seq: 1, segment: segment_upload("seg-one") }, headers: @auth
        assert_response :ok
        assert_equal 2, @session.transcript_segments.count

        # Re-POST seq 0: one row, and the already-done segment is not re-transcribed
        # (the job's atomic claim no-ops on a "done" row).
        post segments_url, params: { seq: 0, segment: segment_upload("seg-zero-again") }, headers: @auth
        assert_response :ok
        assert_equal 2, @session.transcript_segments.count, "re-POSTing a seq must not create a second row"
        assert_requested :post, %r{/v1/audio/transcriptions}, times: 2

        post audio_url, params: { audio: single_shot_upload("full-storage-audio") }, headers: @auth
        assert_response :ok
        post commit_url, headers: @auth
        assert_response :accepted
        assert_equal "completed", @session.reload.status
        assert_not_nil @session.transcript

        # Re-commit from completed is rejected and re-runs no ASR.
        post commit_url, headers: @auth
        assert_response :conflict
        assert_requested :post, %r{/v1/audio/transcriptions}, times: 2
      end

      test "a failed segment falls back to a whole-file ASR pass without double-charging :asr" do
        # ASR sequence: segment arrival fails, the commit-time inline retry fails,
        # and only the whole-file fallback succeeds — so the segment stays failed
        # and the completeness fallback is exercised.
        Scribe::AsrStage.any_instance.stubs(:call)
          .raises(Llm::BadResponse.new("segment boom")).then
          .raises(Llm::BadResponse.new("segment boom")).then
          .returns(Scribe::AsrStage::Result.new(
            text: "whole file transcript", language: "en",
            duration_seconds: 3.0, model: "whisper-1", provider: "openai_compatible",
            usage: nil
          ))

        post segments_url, params: { seq: 0, segment: segment_upload("seg-zero") }, headers: @auth
        assert_response :ok
        assert_equal "failed", @session.transcript_segments.find_by(seq: 0).status,
                     "a segment whose ASR raised must be left failed"

        # A storage blob must exist for the whole-file fallback to read.
        post audio_url, params: { audio: single_shot_upload("full-storage-audio") }, headers: @auth
        assert_response :ok

        asr_before = asr_usage_event_count
        assert_equal 0, asr_before, "a failed segment must not be metered"

        post commit_url, headers: @auth
        assert_response :accepted

        @session.reload
        assert_equal "completed", @session.status
        assert_not_nil @session.transcript
        assert_equal "whole file transcript", @session.transcript.text,
                     "the whole-file fallback must yield a complete transcript"

        assert_equal asr_before, asr_usage_event_count,
                     "the whole-file fallback must NOT record a second :asr usage_event"
      end

      test "with the incremental flag OFF the segments endpoint 404s and commit uses the whole-file ASR path" do
        Scribe::Incremental.stubs(:enabled?).returns(false)

        post segments_url, params: { seq: 0, segment: segment_upload("seg-zero") }, headers: @auth
        assert_response :not_found
        assert_equal "session_not_found", JSON.parse(response.body).dig("error", "code")
        assert_equal 0, @session.transcript_segments.count, "a 404'd segment must not be stored"

        # The pre-existing single-shot upload + commit path is unchanged.
        post audio_url, params: { audio: single_shot_upload("full-storage-audio") }, headers: @auth
        assert_response :ok
        post commit_url, headers: @auth
        assert_response :accepted

        @session.reload
        assert_equal "completed", @session.status
        assert_not_nil @session.transcript
      end

      test "a segment whose ASR fails still returns 200 and leaves the row failed" do
        Scribe::AsrStage.any_instance.stubs(:call).raises(Llm::BadResponse.new("boom"))

        post segments_url, params: { seq: 0, segment: segment_upload("seg-zero") }, headers: @auth
        assert_response :ok, "a segment-job ASR failure must be swallowed — the store already succeeded"
        assert_equal 0, JSON.parse(response.body)["received"]
        assert_equal "failed", @session.transcript_segments.find_by(seq: 0).status
      end

      test "a negative seq is rejected with 422" do
        post segments_url, params: { seq: -1, segment: segment_upload("x") }, headers: @auth
        assert_response :unprocessable_entity
        assert_equal "validation_error", JSON.parse(response.body).dig("error", "code")
        assert_equal 0, @session.transcript_segments.count
      end

      test "a disallowed segment content-type is rejected with 422 and stores no row" do
        post segments_url, params: { seq: 0, segment: bad_type_upload("x") }, headers: @auth
        assert_response :unprocessable_entity
        assert_equal "validation_error", JSON.parse(response.body).dig("error", "code")
        assert_equal 0, @session.transcript_segments.count
      end

      test "a codec-parameterized content-type is accepted and normalized to audio/webm" do
        file = Tempfile.new([ "segment", ".webm" ])
        file.binmode
        file.write("opus-bytes")
        file.rewind
        upload = Rack::Test::UploadedFile.new(file.path, "audio/webm;codecs=opus")

        post segments_url, params: { seq: 0, segment: upload }, headers: @auth
        assert_response :ok
        assert_equal "audio/webm", @session.transcript_segments.find_by(seq: 0).content_type
      end

      private

      def segments_url
        "/api/v2/scribe_sessions/#{@session.id}/audio/segments"
      end

      def audio_url
        "/api/v2/scribe_sessions/#{@session.id}/audio"
      end

      def commit_url
        "/api/v2/scribe_sessions/#{@session.id}/commit"
      end

      def show_url
        "/api/v2/scribe_sessions/#{@session.id}"
      end

      def asr_usage_event_count
        UsageEvent.where(scribe_session_id: @session.id, function: "asr").count
      end

      # A standalone webm transcription segment carrying the given bytes.
      def segment_upload(bytes)
        file = Tempfile.new([ "segment", ".webm" ])
        file.binmode
        file.write(bytes)
        file.rewind
        Rack::Test::UploadedFile.new(file.path, "audio/webm")
      end

      # The single-shot STORAGE recording (a separate stream from segments).
      def single_shot_upload(bytes)
        file = Tempfile.new([ "single", ".webm" ])
        file.binmode
        file.write(bytes)
        file.rewind
        Rack::Test::UploadedFile.new(file.path, "audio/webm")
      end

      # A part declared with a non-audio content-type (rejected by the allowlist).
      def bad_type_upload(bytes)
        file = Tempfile.new([ "segment", ".bin" ])
        file.binmode
        file.write(bytes)
        file.rewind
        Rack::Test::UploadedFile.new(file.path, "application/octet-stream")
      end

      def stub_openai!
        stub_request(:post, %r{https://api\.openai\.com/v1/audio/transcriptions})
          .to_return(
            status: 200,
            headers: { "Content-Type" => "application/json" },
            body: { text: "patient reports headache", language: "en" }.to_json
          )

        stub_request(:post, %r{https://api\.openai\.com/v1/chat/completions})
          .to_return(
            status: 200,
            headers: { "Content-Type" => "application/json" },
            body: {
              choices: [
                {
                  message: { content: { complaint: "headache" }.to_json },
                  finish_reason: "stop"
                }
              ],
              usage: { prompt_tokens: 10, completion_tokens: 5, total_tokens: 15 }
            }.to_json
          )
      end
    end
  end
end
