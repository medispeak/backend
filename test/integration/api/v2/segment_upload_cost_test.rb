require "test_helper"

module Api
  module V2
    # What ONE live segment upload costs the server.
    #
    # This is the hottest write path in the product: during a consultation every
    # clinician POSTs a segment every few seconds, and each one occupies one of
    # the web tier's three Puma threads for the whole request. These tests pin
    # the costs that are invisible in a functional test but decide whether ten
    # concurrent recorders fit on the box:
    #
    #   - no speculative background work is queued behind the upload,
    #   - the work per upload does not grow with the length of the consultation,
    #   - the caller's credential is resolved once, not once per middleware layer.
    class SegmentUploadCostTest < ActionDispatch::IntegrationTest
      setup do
        Rails.cache.clear if Rails.cache.respond_to?(:clear)

        @account = create(:account)
        @user = create(:user, account: @account)
        @token = create(:api_token, user: @user, account: @account)
        @session = create(:scribe_session, account: @account, api_token: @token, user: @user)
        @session_token, = Scribe::SessionToken.mint(@session)
        @auth = { "Authorization" => "Bearer #{@session_token}" }

        @prev_openai_token = ENV["OPENAI_ACCESS_TOKEN"]
        ENV["OPENAI_ACCESS_TOKEN"] = "test-key"
        stub_request(:post, "https://api.openai.com/v1/audio/transcriptions").to_return(
          status: 200,
          headers: { "Content-Type" => "application/json" },
          body: { text: "hello" }.to_json
        )
      end

      teardown do
        Rails.cache.clear if Rails.cache.respond_to?(:clear)
        ENV["OPENAI_ACCESS_TOKEN"] = @prev_openai_token
      end

      # Production has no ffprobe (the DO ruby buildpack ships none), so Active
      # Storage's audio analyzer can only download the blob, shell out, fail, and
      # write nothing — one wasted job and one wasted S3 GET for every segment,
      # competing with transcription for the worker's three threads.
      test "uploading a segment queues transcription and nothing else" do
        with_test_adapter do
          post segments_url, params: { seq: 0, segment: segment_upload("seg-zero") }, headers: @auth
          assert_response :ok

          enqueued = enqueued_jobs.map { |j| j["job_class"] || j[:job].to_s }
          assert_includes enqueued, "TranscribeSegmentJob"
          assert_not_includes enqueued, "ActiveStorage::AnalyzeJob",
                              "analysis cannot measure anything without ffprobe; it only costs a job and an S3 download"
        end
      end

      # The running-total byte cap used to load every previously uploaded
      # segment (plus its attachment and blob rows) into Ruby on each upload, so
      # a 30-minute consultation paid O(n) per POST and O(n^2) overall. The
      # query COUNT hid this (the preload is a fixed three statements) — the cost
      # is in the rows those statements drag back, so count the records built.
      test "upload cost does not grow with the number of segments already uploaded" do
        post segments_url, params: { seq: 0, segment: segment_upload("first") }, headers: @auth
        assert_response :ok
        baseline = count_records do
          post segments_url, params: { seq: 1, segment: segment_upload("second") }, headers: @auth
        end
        assert_response :ok

        (2..9).each do |seq|
          post segments_url, params: { seq: seq, segment: segment_upload("filler-#{seq}") }, headers: @auth
          assert_response :ok
        end

        later = count_records do
          post segments_url, params: { seq: 10, segment: segment_upload("eleventh") }, headers: @auth
        end
        assert_response :ok

        assert_equal baseline, later,
                     "the 11th segment of a consultation must cost the same as the 2nd"
      end

      # Rack::Attack resolves the caller to find the account whose rate budget to
      # spend, and the controller then resolved the very same credential again.
      test "the caller's credential is resolved once per request" do
        token_lookups = with_test_adapter do
          count_queries(matching: /\bapi_tokens\b/) do
            post segments_url, params: { seq: 0, segment: segment_upload("seg-zero") }, headers: @auth
          end
        end
        assert_response :ok

        assert_operator token_lookups, :<=, 1,
                        "throttling and the controller must share one credential resolution"
      end

      test "an account token is also resolved only once" do
        headers = { "Authorization" => "Bearer #{@token.raw_token}" }

        token_lookups = count_queries(matching: /\bapi_tokens\b/) do
          get "/api/v2/scribe_sessions/#{@session.id}", headers: headers
        end
        assert_response :accepted

        assert_operator token_lookups, :<=, 1,
                        "throttling and the controller must share one credential resolution"
      end

      private

      def count_queries(matching: nil)
        count = 0
        sub = ActiveSupport::Notifications.subscribe("sql.active_record") do |*, payload|
          next if payload[:name].to_s.in?([ "SCHEMA", "TRANSACTION" ])
          next if matching && !payload[:sql].to_s.match?(matching)

          count += 1
        end
        yield
        count
      ensure
        ActiveSupport::Notifications.unsubscribe(sub)
      end

      # Active Record objects built while the block runs — the cost that grows
      # with a long consultation, which a query count cannot see.
      def count_records
        count = 0
        sub = ActiveSupport::Notifications.subscribe("instantiation.active_record") do |*, payload|
          count += payload[:record_count].to_i
        end
        yield
        count
      ensure
        ActiveSupport::Notifications.unsubscribe(sub)
      end

      def with_test_adapter
        old = ActiveJob::Base.queue_adapter
        ActiveJob::Base.queue_adapter = :test
        yield
      ensure
        ActiveJob::Base.queue_adapter = old
      end

      def segments_url
        "/api/v2/scribe_sessions/#{@session.id}/audio/segments"
      end

      def segment_upload(bytes)
        file = Tempfile.new([ "segment", ".webm" ])
        file.binmode
        file.write(bytes)
        file.rewind
        Rack::Test::UploadedFile.new(file.path, "audio/webm")
      end
    end
  end
end
