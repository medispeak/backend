require "test_helper"
require "mocha/minitest"

module Api
  module V2
    # Regression coverage for the 2026-07 audit fixes on the v2 scribe surface:
    # cross-tenant page_id, unconditional status reset on /audio, param-missing
    # 500s, the commit race guard, and the realtime/live-form credit gates.
    class AuditFixesTest < ActionDispatch::IntegrationTest
      setup do
        Rails.cache.clear if Rails.cache.respond_to?(:clear)
        @account = create(:account)
        @user = create(:user, account: @account)
        @token = create(:api_token, user: @user, account: @account)
        @headers = { "Authorization" => "Bearer #{@token.raw_token}" }
      end

      # ---- Cross-tenant page_id (finding 7) --------------------------------

      test "create rejects another tenant's page_id (cross-account form-schema read)" do
        other = create(:account)
        foreign_page = create(:page, template: create(:template, account: other))

        post "/api/v2/scribe_sessions", headers: @headers, as: :json, params: {
          outputs: [ { type: "form", page_id: foreign_page.id } ]
        }
        assert_response :unprocessable_entity
        assert_match(/does not reference an existing page/, JSON.parse(response.body).dig("error", "message"))
      end

      test "create accepts the caller's own page_id and legacy shared (account_id NULL) pages" do
        own = create(:page, template: create(:template, account: @account))
        legacy = create(:page, template: create(:template, account: nil))

        [ own, legacy ].each do |page|
          post "/api/v2/scribe_sessions", headers: @headers, as: :json, params: {
            outputs: [ { type: "form", page_id: page.id } ]
          }
          assert_response :created, "page #{page.id} (account=#{page.template.account_id.inspect}) should be usable"
        end
      end

      # ---- POST /audio status reset (finding 14) ---------------------------

      test "POST /audio is rejected once the session is terminal (no reopening the commit gate)" do
        session = create(:scribe_session, account: @account, api_token: @token, user: @user, status: "completed")
        tok, = Scribe::SessionToken.mint(session)

        post "/api/v2/scribe_sessions/#{session.id}/audio",
             params: { audio: upload("bytes") }, headers: { "Authorization" => "Bearer #{tok}" }

        assert_response :conflict
        assert_equal "completed", session.reload.status, "a completed session must not revert to uploading"
      end

      # ---- Param-missing -> 422 not 500 (finding 20) -----------------------

      test "a missing chunk param returns 422 validation_error, not a 500" do
        Scribe::Incremental.stubs(:enabled?).returns(true)
        session = create(:scribe_session, account: @account, api_token: @token, user: @user)
        tok, = Scribe::SessionToken.mint(session)

        post "/api/v2/scribe_sessions/#{session.id}/audio/chunks",
             params: { seq: 0 }, headers: { "Authorization" => "Bearer #{tok}" } # no :chunk

        assert_response :unprocessable_entity
        assert_equal "validation_error", JSON.parse(response.body).dig("error", "code")
      end

      # ---- Commit race guard (finding 4) -----------------------------------

      test "committing a session already in processing is a 409 and enqueues nothing" do
        session = create(:scribe_session, account: @account, api_token: @token, user: @user, status: "processing")
        session.audio_files.attach(io: StringIO.new("a"), filename: "a.mp3", content_type: "audio/mpeg")
        tok, = Scribe::SessionToken.mint(session)

        # The atomic claim only matches committable statuses, so a session already
        # in processing loses the claim -> 409, and the pipeline is not enqueued.
        ProcessScribeSessionJob.expects(:perform_later).never
        post "/api/v2/scribe_sessions/#{session.id}/commit", headers: { "Authorization" => "Bearer #{tok}" }
        assert_response :conflict
      end

      # ---- Realtime credit gate (findings 5/16) ----------------------------

      test "realtime_token is 402 for a broke account and mints nothing" do
        Scribe::Realtime.stubs(:enabled?).returns(true)
        create(:account_credit, account: @account, balance: 0)
        session = create(:scribe_session, account: @account, api_token: @token, user: @user)
        tok, = Scribe::SessionToken.mint(session)

        Scribe::RealtimeToken.expects(:call).never
        post "/api/v2/scribe_sessions/#{session.id}/realtime_token", headers: { "Authorization" => "Bearer #{tok}" }

        assert_response :payment_required
        assert_equal "insufficient_credit", JSON.parse(response.body).dig("error", "code")
      end

      test "live_form returns empty (no LLM) for an in-debt account even with the flag on" do
        Scribe::Incremental.stubs(:live_form_enabled?).returns(true)
        create(:account_credit, account: @account, balance: -1) # negative -> blocked
        session = create(:scribe_session, account: @account, api_token: @token, user: @user)
        tok, = Scribe::SessionToken.mint(session)

        Scribe::LiveStructurer.any_instance.expects(:call).never
        get "/api/v2/scribe_sessions/#{session.id}/live_form", headers: { "Authorization" => "Bearer #{tok}" }

        assert_response :ok
        assert_equal({}, JSON.parse(response.body).fetch("structured_data"))
      end

      private

      def upload(bytes)
        file = Tempfile.new([ "a", ".webm" ])
        file.binmode
        file.write(bytes)
        file.rewind
        Rack::Test::UploadedFile.new(file.path, "audio/webm")
      end
    end
  end
end
