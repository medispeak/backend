require "test_helper"
require "mocha/minitest"

class ProcessScribeSessionJobTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  ASR_URL = "https://api.openai.com/v1/audio/transcriptions".freeze
  CHAT_URL = "https://api.openai.com/v1/chat/completions".freeze

  def attach_audio(session)
    session.audio_files.attach(
      io: StringIO.new("x"), filename: "a.mp3", content_type: "audio/mpeg"
    )
  end

  def stub_asr(text: "the patient has a fever")
    stub_request(:post, ASR_URL).to_return(
      status: 200,
      headers: { "Content-Type" => "application/json" },
      body: { text: text }.to_json
    )
  end

  def stub_chat(content)
    stub_request(:post, CHAT_URL).to_return(
      status: 200,
      headers: { "Content-Type" => "application/json" },
      body: {
        choices: [ { message: { content: content.to_json }, finish_reason: "stop" } ],
        usage: { prompt_tokens: 10, completion_tokens: 4 }
      }.to_json
    )
  end

  def build_session_with_form(account:, callback_url: nil)
    session = create(:scribe_session, account: account, language: "en", callback_url: callback_url)
    attach_audio(session)
    page = create(:page, prompt: "Fill the form.")
    create(:form_field, page: page, title: "diagnosis", friendly_name: "Diagnosis", field_type: "string")
    create(:scribe_output, scribe_session: session, output_type: "transcript")
    create(:scribe_output, scribe_session: session, output_type: "form", page: page)
    session
  end

  test "processes a session to completion and fills outputs" do
    stub_asr(text: "the patient has a fever")
    stub_chat({ "diagnosis" => "fever" })

    account = create(:account)
    session = build_session_with_form(account: account)

    ProcessScribeSessionJob.perform_now(session.id)

    session.reload
    assert_equal "completed", session.status
    assert_not_nil session.transcript
    assert session.scribe_outputs.all?(&:status_success?)
  end

  test "is a no-op when the session does not exist" do
    assert_nothing_raised do
      ProcessScribeSessionJob.perform_now(-1)
    end
  end

  test "marks the session failed without re-raising on an unexpected error" do
    # No audio attached and no stub: ASR finds no blob -> Orchestrator marks the
    # session failed internally. Force a harder failure by stubbing a raise via
    # a non-existent page on a form output instead.
    account = create(:account)
    session = create(:scribe_session, account: account, language: "en")
    attach_audio(session)
    # A form output whose page is nil triggers a NoMethodError inside the
    # per-output rescue, which keeps the session alive; to exercise the job-level
    # rescue we stub the orchestrator to raise.
    Scribe::Orchestrator.stubs(:new).raises(StandardError.new("kaboom"))

    assert_nothing_raised do
      ProcessScribeSessionJob.perform_now(session.id)
    end

    assert_equal "failed", session.reload.status
    assert_equal "kaboom", session.error["message"]
  end

  test "delivers a signed webhook when callback_url is set" do
    stub_asr(text: "the patient has a fever")
    stub_chat({ "diagnosis" => "fever" })

    callback_url = "https://client.example.com/hooks/medispeak"
    webhook_stub = stub_request(:post, callback_url).to_return(status: 200, body: "")

    account = create(:account)
    session = build_session_with_form(account: account, callback_url: callback_url)

    # :inline ActiveJob adapter runs the enqueued ScribeWebhookJob synchronously.
    ProcessScribeSessionJob.perform_now(session.id)

    assert_equal "completed", session.reload.status
    assert_requested(:post, callback_url) do |req|
      header = req.headers["X-Medispeak-Signature"]
      header.present? &&
        header.match?(/\At=\d+,v1=[0-9a-f]{64}\z/) &&
        req.headers["Content-Type"].to_s.include?("application/json")
    end
    assert_requested webhook_stub, times: 1
  end

  # --- Segment settlement (job continuation, no in-job polling) ---

  def add_segment(session, seq:, status:, updated_at: nil)
    seg = session.transcript_segments.create!(seq: seq, status: status)
    seg.data.attach(io: StringIO.new("seg-bytes"), filename: "s.webm", content_type: "audio/webm")
    seg.update_column(:updated_at, updated_at) if updated_at
    seg
  end

  test "settles a pending segment inline and assembles the transcript from segments" do
    stub_asr(text: "settled inline")

    session = create(:scribe_session, account: create(:account), language: "en")
    add_segment(session, seq: 0, status: "pending")
    create(:scribe_output, scribe_session: session, output_type: "transcript")

    ProcessScribeSessionJob.perform_now(session.id)

    session.reload
    assert_equal "completed", session.status
    assert_equal "settled inline", session.transcript.text
    assert_requested :post, ASR_URL, times: 1
  end

  test "re-enqueues itself with a wait while an async segment claim is in flight" do
    old_adapter = ActiveJob::Base.queue_adapter
    ActiveJob::Base.queue_adapter = :test

    session = create(:scribe_session, account: create(:account), language: "en")
    add_segment(session, seq: 0, status: "transcribing")

    assert_enqueued_with(job: ProcessScribeSessionJob, args: [ session.id, 1 ]) do
      ProcessScribeSessionJob.perform_now(session.id)
    end

    assert_equal "processing", session.reload.status,
                 "session stays processing while settlement waits; the client keeps polling"
    assert_nil session.transcript
    assert_not_requested :post, ASR_URL
  ensure
    ActiveJob::Base.queue_adapter = old_adapter
  end

  # The commit almost always races the last segment's ASR (the client commits
  # the instant the final segment upload returns), so the FIRST settle waits
  # decide the user-visible "stop -> note" time. A flat 5s tick charged every
  # commit ~5-6s for a segment that finishes in ~1s; the early attempts are
  # therefore short and only long-running settlements fall back to the coarse
  # tick. The total budget is unchanged (still ~STALE_CLAIM_AGE).
  test "re-enqueues the first settle attempts with the short wait" do
    old_adapter = ActiveJob::Base.queue_adapter
    ActiveJob::Base.queue_adapter = :test

    session = create(:scribe_session, account: create(:account), language: "en")
    add_segment(session, seq: 0, status: "transcribing")

    ProcessScribeSessionJob.perform_now(session.id)

    scheduled_at = enqueued_jobs.last["at"] || enqueued_jobs.last[:at]
    assert_in_delta Time.current.to_f + ProcessScribeSessionJob::FAST_SETTLE_WAIT.to_f,
                    scheduled_at.to_f, 1.0,
                    "the first settle retry must use the short wait, not the 5s tick"
  ensure
    ActiveJob::Base.queue_adapter = old_adapter
  end

  test "falls back to the long settle wait once the fast attempts are exhausted" do
    old_adapter = ActiveJob::Base.queue_adapter
    ActiveJob::Base.queue_adapter = :test

    session = create(:scribe_session, account: create(:account), language: "en")
    add_segment(session, seq: 0, status: "transcribing")

    ProcessScribeSessionJob.perform_now(session.id, ProcessScribeSessionJob::FAST_SETTLE_ATTEMPTS)

    scheduled_at = enqueued_jobs.last["at"] || enqueued_jobs.last[:at]
    assert_in_delta Time.current.to_f + ProcessScribeSessionJob::SETTLE_WAIT.to_f,
                    scheduled_at.to_f, 1.0,
                    "a long-running settlement must back off to the coarse tick"
  ensure
    ActiveJob::Base.queue_adapter = old_adapter
  end

  test "the total settle budget still covers a stale claim" do
    total = (0...ProcessScribeSessionJob::MAX_SETTLE_ATTEMPTS).sum do |attempt|
      ProcessScribeSessionJob.settle_wait_for(attempt).to_f
    end

    assert_operator total, :>=, ProcessScribeSessionJob::STALE_CLAIM_AGE.to_f,
                    "shortening the early waits must not shrink the window a dead worker's claim needs"
  end

  test "reclaims a stale transcribing claim at the attempt bound and finishes inline" do
    stub_asr(text: "reclaimed and transcribed")

    session = create(:scribe_session, account: create(:account), language: "en")
    add_segment(session, seq: 0, status: "transcribing",
                updated_at: 3.minutes.ago)
    create(:scribe_output, scribe_session: session, output_type: "transcript")

    ProcessScribeSessionJob.perform_now(session.id, ProcessScribeSessionJob::MAX_SETTLE_ATTEMPTS)

    session.reload
    assert_equal "completed", session.status
    assert_equal "reclaimed and transcribed", session.transcript.text
  end

  test "a fresh transcribing claim at the attempt bound is NOT reclaimed and fails explicitly" do
    session = create(:scribe_session, account: create(:account), language: "en")
    add_segment(session, seq: 0, status: "transcribing")

    ProcessScribeSessionJob.perform_now(session.id, ProcessScribeSessionJob::MAX_SETTLE_ATTEMPTS)

    session.reload
    assert_equal "failed", session.status
    assert_includes session.error["message"], "segment(s) 0"
    assert_equal "transcribing", session.transcript_segments.first.status,
                 "a live-but-slow worker's claim must not be stolen"
    assert_not_requested :post, ASR_URL
  end

  test "webhook body is PHI-light and carries no transcript text or field values" do
    stub_asr(text: "secret transcript content")
    stub_chat({ "diagnosis" => "secret diagnosis value" })

    callback_url = "https://client.example.com/hooks/phi"
    captured_body = nil
    stub_request(:post, callback_url).to_return do |req|
      captured_body = req.body
      { status: 200, body: "" }
    end

    account = create(:account)
    session = build_session_with_form(account: account, callback_url: callback_url)

    ProcessScribeSessionJob.perform_now(session.id)

    assert_not_nil captured_body
    assert_not_includes captured_body, "secret transcript content"
    assert_not_includes captured_body, "secret diagnosis value"

    parsed = JSON.parse(captured_body)
    assert_equal session.id, parsed["session_id"]
    assert parsed.key?("delivery_id")
    assert parsed.key?("sent_at")
    assert parsed["outputs"].all? { |o| o.keys.sort == %w[id output_type status] }
  end
end
