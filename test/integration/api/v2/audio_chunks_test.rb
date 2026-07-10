require "test_helper"

module Api
  module V2
    # Exercises the native chunked/resumable upload path end-to-end through the
    # browser credential: a scoped session token (Task 2) reaches only its own
    # session's audio/chunks, audio/status, and commit routes.
    class AudioChunksTest < ActionDispatch::IntegrationTest
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
      end

      teardown do
        Rails.cache.clear if Rails.cache.respond_to?(:clear)
        ENV["OPENAI_ACCESS_TOKEN"] = @prev_openai_token
      end

      test "uploads chunks out of order, re-POST of a seq is idempotent, status reports state" do
        # seq 1 first, then seq 0 (out of order).
        post chunks_url, params: { seq: 1, chunk: chunk_upload("lo ") }, headers: @auth
        assert_response :ok
        assert_equal 1, JSON.parse(response.body)["received"]

        post chunks_url, params: { seq: 0, chunk: chunk_upload("hel") }, headers: @auth
        assert_response :ok

        # Re-POST seq 0 with different bytes: one row, latest bytes win.
        post chunks_url, params: { seq: 0, chunk: chunk_upload("HEL") }, headers: @auth
        assert_response :ok

        assert_equal 2, @session.audio_chunks.count, "re-POSTing a seq must not create a second row"
        assert_equal "HEL", @session.audio_chunks.find_by(seq: 0).data.download

        get status_url, headers: @auth
        assert_response :ok
        body = JSON.parse(response.body)
        assert_equal [ 0, 1 ], body["received_seqs"]
        assert_equal false, body["final_seen"]
        assert_equal 6, body["bytes"] # "HEL" (3) + "lo " (3)
      end

      test "the first chunk transitions the session to uploading" do
        assert_equal "created", @session.status
        post chunks_url, params: { seq: 0, chunk: chunk_upload("a") }, headers: @auth
        assert_response :ok
        assert_equal "uploading", @session.reload.status
      end

      test "audio/status reports final_seen once a final chunk arrives" do
        post chunks_url, params: { seq: 0, chunk: chunk_upload("a"), final: true }, headers: @auth
        assert_response :ok

        get status_url, headers: @auth
        assert_response :ok
        assert_equal true, JSON.parse(response.body)["final_seen"]
      end

      test "a chunk larger than the ceiling is rejected 422" do
        big = Rack::Test::UploadedFile.new(oversized_chunk_path, "audio/webm")
        post chunks_url, params: { seq: 0, chunk: big }, headers: @auth
        assert_response :unprocessable_entity
        assert_equal "validation_error", JSON.parse(response.body).dig("error", "code")
        assert_equal 0, @session.audio_chunks.count
      end

      test "audio/chunks on an expired session returns 410" do
        # Authenticated with the account token: its validity is independent of the
        # session's expiry, so the request reaches the endpoint's reject_expired
        # guard. (A session token minted for an expired session is already expired
        # and 401s at auth — see SessionToken.mint's expiry cap.)
        expired = create(:scribe_session, account: @account, api_token: @token,
                                          user: @user, expires_at: 1.hour.ago)
        post "/api/v2/scribe_sessions/#{expired.id}/audio/chunks",
             params: { seq: 0, chunk: chunk_upload("a") },
             headers: @account_headers
        assert_response :gone
        assert_equal "session_expired", JSON.parse(response.body).dig("error", "code")
      end

      test "commit reassembles chunks into one blob equal to the concatenation and runs the pipeline" do
        parts = { 2 => "world", 0 => "hel", 1 => "lo " }
        parts.each do |seq, bytes|
          post chunks_url, params: { seq: seq, chunk: chunk_upload(bytes) }, headers: @auth
          assert_response :ok
        end

        post commit_url, headers: @auth
        assert_response :accepted

        @session.reload
        assert_not_includes %w[created uploading], @session.status, "commit must move the session past upload"
        assert_equal "completed", @session.status
        assert @session.audio_files.attached?
        assert_equal "hello world", @session.audio_files.first.download
        assert_not_nil @session.transcript
      end

      test "resume-then-commit yields the same persisted transcript as a single-shot upload of the concatenated bytes" do
        parts = { 0 => "chunk-zero-", 1 => "chunk-one-", 2 => "chunk-two" }
        concatenated = parts.values.join

        # --- chunked (browser/session-token) path ---
        parts.each do |seq, bytes|
          post chunks_url, params: { seq: seq, chunk: chunk_upload(bytes) }, headers: @auth
          assert_response :ok
        end
        post commit_url, headers: @auth
        assert_response :accepted

        @session.reload
        assert_equal "completed", @session.status
        assert_equal concatenated, @session.audio_files.first.download,
                     "reassembled audio must equal the concatenation of the chunk bytes"
        chunked_text = @session.transcript.text

        # --- single-shot path over the identical concatenated bytes ---
        single = create(:scribe_session, account: @account, api_token: @token, user: @user)
        post "/api/v2/scribe_sessions/#{single.id}/audio",
             params: { audio: single_shot_upload(concatenated) }, headers: @account_headers
        assert_response :ok
        post "/api/v2/scribe_sessions/#{single.id}/commit", headers: @account_headers
        assert_response :accepted

        single.reload
        assert_equal "completed", single.status

        assert_equal single.transcript.text, chunked_text,
                     "chunked resume-then-commit must persist the same transcript as the single-shot upload"
      end

      test "commit with no single-shot blob and no chunks returns 422 audio_upload_failed" do
        post commit_url, headers: @auth
        assert_response :unprocessable_entity
        assert_equal "audio_upload_failed", JSON.parse(response.body).dig("error", "code")

        @session.reload
        assert_nil @session.transcript, "the pipeline must not run without audio"
        assert_not @session.audio_files.attached?
      end

      private

      def chunks_url
        "/api/v2/scribe_sessions/#{@session.id}/audio/chunks"
      end

      def status_url
        "/api/v2/scribe_sessions/#{@session.id}/audio/status"
      end

      def commit_url
        "/api/v2/scribe_sessions/#{@session.id}/commit"
      end

      # A webm audio part carrying the given bytes. audio/webm is in
      # ScribeSession::ALLOWED_AUDIO_TYPES so the reassembled blob validates.
      def chunk_upload(bytes)
        file = Tempfile.new([ "chunk", ".webm" ])
        file.binmode
        file.write(bytes)
        file.rewind
        Rack::Test::UploadedFile.new(file.path, "audio/webm")
      end

      def single_shot_upload(bytes)
        file = Tempfile.new([ "single", ".webm" ])
        file.binmode
        file.write(bytes)
        file.rewind
        Rack::Test::UploadedFile.new(file.path, "audio/webm")
      end

      # A sparse file one byte over the per-chunk ceiling, declared as valid audio
      # so the size check (not the content-type) is what rejects it.
      def oversized_chunk_path
        file = Tempfile.new([ "bigchunk", ".webm" ])
        file.binmode
        file.truncate(Api::V2::ScribeSessionsController::MAX_CHUNK_BYTES + 1)
        file.rewind
        file.path
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
