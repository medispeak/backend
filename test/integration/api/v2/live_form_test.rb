require "test_helper"
require "mocha/minitest"

module Api
  module V2
    # Exercises the live form-fill endpoint (GET :id/live_form): structuring the
    # growing LIVE transcript DURING recording so a client can pre-fill the form
    # before commit. Gated behind Scribe::Incremental.live_form_enabled? — OFF by
    # default (returns an empty object rather than 404 so a poller degrades
    # gracefully), ON here to assert the structured pre-fill.
    class LiveFormTest < ActionDispatch::IntegrationTest
      setup do
        Rails.cache.clear if Rails.cache.respond_to?(:clear)

        @account = create(:account)
        @user = create(:user, account: @account)
        @token = create(:api_token, user: @user, account: @account)

        @session = create(:scribe_session, account: @account, api_token: @token, user: @user)
        @session.scribe_outputs.create!(
          status: "pending", output_type: "form",
          inline_fields: [ { "key" => "complaint", "label" => "Complaint", "type" => "string" } ]
        )
        @session_token, = Scribe::SessionToken.mint(@session)
        @auth = { "Authorization" => "Bearer #{@session_token}" }

        @prev_openai_token = ENV["OPENAI_ACCESS_TOKEN"]
        ENV["OPENAI_ACCESS_TOKEN"] = "test-key"
        stub_openai!

        # Both flags ON: the incremental path feeds the live transcript, and the
        # live-form flag opens the structuring endpoint.
        Scribe::Incremental.stubs(:enabled?).returns(true)
        Scribe::Incremental.stubs(:live_form_enabled?).returns(true)
      end

      teardown do
        Rails.cache.clear if Rails.cache.respond_to?(:clear)
        ENV["OPENAI_ACCESS_TOKEN"] = @prev_openai_token
      end

      test "structures the live transcript into the form's fields during recording" do
        # One segment finishes ASR inline, so the session has a live transcript.
        post segments_url, params: { seq: 0, segment: segment_upload("seg-zero") }, headers: @auth
        assert_response :ok
        assert @session.reload.live_transcript.present?, "precondition: a live transcript exists"

        get live_form_url, headers: @auth
        assert_response :ok
        data = JSON.parse(response.body).fetch("structured_data")
        assert_equal "headache", data["complaint"],
                     "the live transcript should be structured into the form's fields"
      end

      test "returns an empty object before any segment finishes (blank live transcript)" do
        get live_form_url, headers: @auth
        assert_response :ok
        assert_equal({}, JSON.parse(response.body).fetch("structured_data"),
                     "no transcript yet -> nothing to structure")
        assert_not_requested :post, %r{/v1/chat/completions}
      end

      test "with the live-form flag OFF the endpoint returns an empty object and runs no structuring" do
        Scribe::Incremental.stubs(:live_form_enabled?).returns(false)

        post segments_url, params: { seq: 0, segment: segment_upload("seg-zero") }, headers: @auth
        assert_response :ok
        assert @session.reload.live_transcript.present?

        get live_form_url, headers: @auth
        assert_response :ok
        assert_equal({}, JSON.parse(response.body).fetch("structured_data"),
                     "flag off -> no pre-fill")
        assert_not_requested :post, %r{/v1/chat/completions}
      end

      test "a foreign session token cannot read another session's live form" do
        other = create(:scribe_session, account: create(:account))
        other_token, = Scribe::SessionToken.mint(other)
        get live_form_url, headers: { "Authorization" => "Bearer #{other_token}" }
        assert_response :not_found
      end

      private

      def segments_url
        "/api/v2/scribe_sessions/#{@session.id}/audio/segments"
      end

      def live_form_url
        "/api/v2/scribe_sessions/#{@session.id}/live_form"
      end

      def segment_upload(bytes)
        file = Tempfile.new([ "segment", ".webm" ])
        file.binmode
        file.write(bytes)
        file.rewind
        Rack::Test::UploadedFile.new(file.path, "audio/webm")
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
