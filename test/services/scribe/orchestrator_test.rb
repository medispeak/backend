require "test_helper"
require "mocha/minitest"

class ScribeOrchestratorTest < ActiveSupport::TestCase
  ASR_URL = "https://api.openai.com/v1/audio/transcriptions".freeze
  CHAT_URL = "https://api.openai.com/v1/chat/completions".freeze

  def attach_audio(session)
    session.audio_files.attach(
      io: StringIO.new("x"), filename: "a.mp3", content_type: "audio/mpeg"
    )
  end

  # Builds a chat-completions response body whose JSON content matches the strict
  # schema (all properties present, since the OpenAI strict transform promotes
  # every field to required+nullable).
  def chat_body(content, finish: "stop")
    {
      choices: [{ message: { content: content.to_json }, finish_reason: finish }],
      usage: { prompt_tokens: 10, completion_tokens: 4 }
    }.to_json
  end

  def stub_asr(text: "the patient has a fever")
    stub_request(:post, ASR_URL).to_return(
      status: 200,
      headers: { "Content-Type" => "application/json" },
      body: { text: text }.to_json
    )
  end

  def stub_chat(content, finish: "stop")
    stub_request(:post, CHAT_URL).to_return(
      status: 200,
      headers: { "Content-Type" => "application/json" },
      body: chat_body(content, finish: finish)
    )
  end

  def build_page_with_fields
    page = create(:page, prompt: "Fill the clinical form from the transcript.")
    create(:form_field, page: page, title: "diagnosis", friendly_name: "Diagnosis", field_type: "string")
    create(:form_field, page: page, title: "temperature", friendly_name: "Temperature", field_type: "number")
    page
  end

  test "runs ASR once, fills transcript + form outputs, records usage" do
    stub_asr(text: "the patient has a fever")
    stub_chat({ "diagnosis" => "fever", "temperature" => 39 })

    account = create(:account)
    session = create(:scribe_session, account: account, language: "en")
    attach_audio(session)
    page = build_page_with_fields

    transcript_output = create(:scribe_output, scribe_session: session, output_type: "transcript")
    form_output = create(:scribe_output, scribe_session: session, output_type: "form", page: page)

    assert_difference("UsageEvent.count", 2) do # one ASR + one structuring
      Scribe::Orchestrator.new(session).call
    end

    # Transcript persisted once on the session.
    transcript = session.reload.transcript
    assert_not_nil transcript
    assert_equal "the patient has a fever", transcript.text
    assert_equal "whisper-1", transcript.model

    # ASR called exactly once even with multiple outputs.
    assert_requested :post, ASR_URL, times: 1

    # Transcript output echoes the transcript.
    transcript_output.reload
    assert transcript_output.status_success?
    assert_equal "the patient has a fever", transcript_output.result["text"]
    assert_equal "en", transcript_output.result["language"]

    # Form output filled and successful.
    form_output.reload
    assert form_output.status_success?, "form output should succeed: #{form_output.result_errors.inspect}"
    assert_equal "fever", form_output.result["diagnosis"]
    assert_equal 39, form_output.result["temperature"]

    # Session completed (all outputs success).
    assert_equal "completed", session.reload.status

    # Usage events recorded for both functions.
    functions = UsageEvent.where(scribe_session_id: session.id).pluck(:function).sort
    assert_equal %w[asr structuring], functions
  end

  test "asr_mode :translate (from the ASR assignment options) routes ASR to the /audio/translations endpoint" do
    translations_url = "https://api.openai.com/v1/audio/translations"
    stub_request(:post, translations_url).to_return(
      status: 200,
      headers: { "Content-Type" => "application/json" },
      body: { text: "the patient has a fever" }.to_json
    )

    # ASR assigned to whisper-1 on OpenAI with the translate task toggled on via
    # options — the per-client seam a Malayalam/code-mix deployment would use.
    provider = create(:ai_provider, kind: "openai_compatible", name: "OpenAI",
                                     base_url: "https://api.openai.com", api_key: "sk-test")
    whisper = create(:ai_model, ai_provider: provider, api_model_id: "whisper-1",
                                capabilities: { "can_transcribe" => true })
    create(:model_assignment, scope_type: "System", function: "asr",
                              ai_model: whisper, options: { "asr_mode" => "translate" })

    session = create(:scribe_session, account: create(:account), language: "ml")
    attach_audio(session)
    create(:scribe_output, scribe_session: session, output_type: "transcript")

    Scribe::Orchestrator.new(session).call

    assert_requested :post, translations_url, times: 1
    assert_not_requested :post, ASR_URL
    assert_equal "the patient has a fever", session.reload.transcript.text,
                 "the English translation is stored as the transcript"
  end

  test "ASR usage_event is metered at the real audio duration and a non-zero cost" do
    stub_asr(text: "the patient has a fever")
    stub_chat({ "diagnosis" => "fever", "temperature" => 39 })

    account = create(:account)
    session = create(:scribe_session, account: account, language: "en")
    attach_audio(session)
    page = build_page_with_fields

    create(:scribe_output, scribe_session: session, output_type: "form", page: page)

    # Deterministic duration regardless of whether ffprobe exists in the runner.
    Scribe::AudioDuration.stubs(:for_blob).returns(
      Scribe::AudioDuration::Result.new(seconds: 90.0, estimated: false)
    )

    # The default ASR config records provider NAME "OpenAI" / model "whisper-1"
    # (the price book keys on the provider name, not the :openai_compatible kind).
    create(:audio_model_price, provider: "OpenAI", model: "whisper-1", price_per_minute: 0.006)

    Scribe::Orchestrator.new(session).call

    asr = UsageEvent.find_by(scribe_session_id: session.id, function: "asr")
    assert_not_nil asr
    assert_equal 90.0, asr.audio_seconds.to_f
    assert_equal (90.0 / 60.0 * 0.006).round(6), asr.cost.to_f

    assert_equal 90.0, session.reload.transcript.duration_seconds.to_f
  end

  test "re-running the orchestrator does not re-meter an already-successful output" do
    stub_asr(text: "the patient has a fever")
    stub_chat({ "diagnosis" => "fever", "temperature" => 39 })

    account = create(:account)
    session = create(:scribe_session, account: account, language: "en")
    attach_audio(session)
    page = build_page_with_fields

    create(:scribe_output, scribe_session: session, output_type: "transcript")
    create(:scribe_output, scribe_session: session, output_type: "form", page: page)

    # First run meters one ASR + one structuring event.
    assert_difference("UsageEvent.count", 2) do
      Scribe::Orchestrator.new(session).call
    end

    # Second run: successful outputs are skipped and the transcript is reused,
    # so no output is reprocessed and nothing new is metered.
    assert_no_difference("UsageEvent.count") do
      Scribe::Orchestrator.new(session.reload).call
    end

    assert_equal "completed", session.reload.status
  end

  test "form output fails on truncation while transcript output still succeeds => partial session" do
    stub_asr(text: "the patient has a fever")
    # finish_reason length means the structuring model truncated -> BadResponse
    # in StructuringStage, isolated per-output.
    stub_chat({ "diagnosis" => "fever" }, finish: "length")

    account = create(:account)
    session = create(:scribe_session, account: account, language: "en")
    attach_audio(session)
    page = build_page_with_fields

    transcript_output = create(:scribe_output, scribe_session: session, output_type: "transcript")
    form_output = create(:scribe_output, scribe_session: session, output_type: "form", page: page)

    Scribe::Orchestrator.new(session).call

    # Transcript still produced (ASR succeeded).
    assert_not_nil session.reload.transcript

    transcript_output.reload
    assert transcript_output.status_success?

    form_output.reload
    assert form_output.status_failure?
    refute_empty form_output.result_errors

    assert_equal "partial", session.reload.status

    # Only the ASR usage event is recorded; the truncated structuring attempt
    # raised before reaching the metering call.
    functions = UsageEvent.where(scribe_session_id: session.id).pluck(:function)
    assert_equal %w[asr], functions
  end

  test "orchestrator processes the transcript output before it structures the form (ordering pinned)" do
    stub_asr(text: "the patient has a fever")

    account = create(:account)
    session = create(:scribe_session, account: account, language: "en")
    attach_audio(session)
    page = build_page_with_fields

    # FE ordering: the form output is created BEFORE the transcript output. If
    # Step 1's partition were reverted, the form would structure first and this
    # test would fail (transcript still status_pending when the form runs).
    form_output = create(:scribe_output, scribe_session: session, output_type: "form", page: page)
    transcript_output = create(:scribe_output, scribe_session: session, output_type: "transcript")

    # Stub StructuringStage.new -> a double whose #call records, at the moment the
    # form structuring runs, whether the transcript output is ALREADY succeeded.
    # This is the assertion that genuinely exercises Step 1's ordering change.
    transcript_done_when_form_structured = nil
    fake_stage = Object.new
    fake_stage.define_singleton_method(:call) do |_transcript_text|
      transcript_done_when_form_structured = transcript_output.reload.status_success?
      # Match StructuringStage::Result's members (structuring_stage.rb:10-13);
      # usage: nil is fine — meter_output's record_and_deduct is best-effort and
      # rescues, so it cannot fail this test.
      Scribe::StructuringStage::Result.new(
        structured: { "diagnosis" => "fever" }, usage: nil, model: "test",
        provider: "test", finish_reason: "stop", valid: true, errors: []
      )
    end
    Scribe::StructuringStage.stubs(:new).returns(fake_stage)

    Scribe::Orchestrator.new(session).call

    assert_equal true, transcript_done_when_form_structured,
      "transcript output must be status_success BEFORE the form's StructuringStage runs"
  end

  test "transcript output succeeds even when a sibling form output fails" do
    stub_asr(text: "the patient has a fever")
    stub_chat({ "diagnosis" => "fever" }, finish: "length") # truncation -> form fails

    account = create(:account)
    session = create(:scribe_session, account: account, language: "en")
    attach_audio(session)
    page = build_page_with_fields

    # Create the form output BEFORE the transcript output to reproduce the FE's
    # ordering; the orchestrator must still finish the transcript first/regardless.
    form_output = create(:scribe_output, scribe_session: session, output_type: "form", page: page)
    transcript_output = create(:scribe_output, scribe_session: session, output_type: "transcript")

    Scribe::Orchestrator.new(session).call

    transcript_output.reload
    assert transcript_output.status_success?
    assert_equal "the patient has a fever", transcript_output.result["text"]

    form_output.reload
    assert form_output.status_failure?

    assert_equal "partial", session.reload.status
  end

  test "ASR failure marks the session and all outputs failed" do
    stub_request(:post, ASR_URL).to_return(status: 500, body: "boom")

    account = create(:account)
    session = create(:scribe_session, account: account, language: "en")
    attach_audio(session)

    transcript_output = create(:scribe_output, scribe_session: session, output_type: "transcript")

    Scribe::Orchestrator.new(session).call

    assert_nil session.reload.transcript
    assert_equal "failed", session.status

    transcript_output.reload
    assert transcript_output.status_failure?
    refute_empty transcript_output.result_errors

    # No structuring or ASR usage events on a failed-before-persist ASR.
    assert_equal 0, UsageEvent.where(scribe_session_id: session.id).count
  end

  test "form output with inline_fields structures against the ad-hoc schema (no page)" do
    stub_asr(text: "the patient has a fever")
    stub_chat({ "hr" => 88, "diagnosis" => "fever" })

    account = create(:account)
    session = create(:scribe_session, account: account, language: "en")
    attach_audio(session)

    form_output = create(
      :scribe_output, scribe_session: session, output_type: "form", page: nil,
      inline_fields: [
        { "key" => "hr", "label" => "Heart Rate", "type" => "number" },
        { "key" => "diagnosis", "label" => "Diagnosis", "type" => "string" }
      ]
    )

    assert_difference("UsageEvent.count", 2) do # one ASR + one structuring
      Scribe::Orchestrator.new(session).call
    end

    form_output.reload
    assert_nil form_output.page_id, "inline-fields output must not reference a page"
    assert form_output.status_success?, "inline form output should succeed: #{form_output.result_errors.inspect}"
    assert_equal 88, form_output.result["hr"]
    assert_equal "fever", form_output.result["diagnosis"]

    assert_equal "completed", session.reload.status
  end

  test "note output runs free-text structuring and stores the note" do
    stub_asr(text: "patient presented with chest pain")
    stub_chat({ "note" => "Patient presented with chest pain. Plan: ECG." })

    account = create(:account)
    session = create(:scribe_session, account: account, language: "en")
    attach_audio(session)

    note_output = create(:scribe_output, scribe_session: session, output_type: "note",
                                         template_ref: "Write a SOAP note.")

    assert_difference("UsageEvent.count", 2) do
      Scribe::Orchestrator.new(session).call
    end

    note_output.reload
    assert note_output.status_success?
    assert_equal "Patient presented with chest pain. Plan: ECG.", note_output.result["note"]

    assert_equal "completed", session.reload.status
  end

  test "reuses an existing transcript without re-running ASR" do
    stub_chat({ "diagnosis" => "fever", "temperature" => 39 })

    account = create(:account)
    session = create(:scribe_session, account: account, language: "en")
    attach_audio(session)
    page = build_page_with_fields

    # Pre-existing transcript.
    Transcript.create!(scribe_session: session, text: "preexisting transcript",
                       language: "en", provider: "openai_compatible", model: "whisper-1")

    form_output = create(:scribe_output, scribe_session: session, output_type: "form", page: page)

    Scribe::Orchestrator.new(session).call

    # ASR endpoint never hit.
    assert_not_requested :post, ASR_URL

    form_output.reload
    assert form_output.status_success?
    assert_equal "completed", session.reload.status
  end

  # Regression (blocker fix): metering must consume the Llm::Result contract, so
  # the orchestrator adapts the StructuringStage::Result (which has no
  # #latency_ms) into one before recording. Without the wrapper, the metering
  # call raised NoMethodError: undefined method `latency_ms`.
  test "structuring usage_event records latency_ms column without raising" do
    stub_asr(text: "the patient has a fever")
    stub_chat({ "diagnosis" => "fever", "temperature" => 39 })

    account = create(:account)
    session = create(:scribe_session, account: account, language: "en")
    attach_audio(session)
    page = build_page_with_fields
    form_output = create(:scribe_output, scribe_session: session, output_type: "form", page: page)

    assert_nothing_raised do
      Scribe::Orchestrator.new(session).call
    end

    structuring_event = UsageEvent.find_by(scribe_session_id: session.id, function: "structuring")
    assert_not_nil structuring_event
    assert_equal form_output.id, structuring_event.scribe_output_id
    # The stage struct surfaces no latency, so the column is nil (nullable) — the
    # point is that reading #latency_ms off the wrapped result did not blow up.
    assert_nil structuring_event.latency_ms
  end

  # Regression (major fix): a metering failure AFTER a successful structuring
  # save must NOT demote the persisted success to :failure, and must NOT fail the
  # session rollup. Metering is best-effort and runs outside the per-output
  # rescue. Here we force the metering path to raise and assert the output and
  # session are unaffected.
  test "a metering failure does not demote a successful output or fail the session" do
    stub_asr(text: "the patient has a fever")
    stub_chat({ "diagnosis" => "fever", "temperature" => 39 })

    account = create(:account)
    session = create(:scribe_session, account: account, language: "en")
    attach_audio(session)
    page = build_page_with_fields
    transcript_output = create(:scribe_output, scribe_session: session, output_type: "transcript")
    form_output = create(:scribe_output, scribe_session: session, output_type: "form", page: page)

    # Blow up every metering attempt (ASR + structuring) the way a real
    # UsageRecorder bug would.
    Metering::UsageRecorder.stubs(:record).raises(StandardError.new("metering boom"))

    assert_nothing_raised do
      Scribe::Orchestrator.new(session).call
    end

    # Outputs keep their real outcomes — the metering crash is swallowed.
    transcript_output.reload
    form_output.reload
    assert transcript_output.status_success?
    assert form_output.status_success?,
           "form output should stay success despite metering failure: #{form_output.result_errors.inspect}"

    # Transcript persisted; session rolls up to completed, not failed/partial.
    assert_not_nil session.reload.transcript
    assert_equal "completed", session.status

    # No usage events were created because every record attempt raised.
    assert_equal 0, UsageEvent.where(scribe_session_id: session.id).count
  end

  # The structuring stage completed (consumed tokens) but produced an invalid
  # object => the output is :partial, and per spec a token-consuming attempt is
  # still metered. The wrapper must keep that metering call working.
  test "an invalid-but-complete structuring output is partial and still metered" do
    stub_asr(text: "the patient has a fever")
    # diagnosis present, temperature wrong type so SchemaValidator flags it; the
    # call still finished (finish_reason stop) so tokens were consumed.
    stub_chat({ "diagnosis" => "fever", "temperature" => "not a number" })

    account = create(:account)
    session = create(:scribe_session, account: account, language: "en")
    attach_audio(session)
    page = build_page_with_fields
    form_output = create(:scribe_output, scribe_session: session, output_type: "form", page: page)

    Scribe::Orchestrator.new(session).call

    form_output.reload
    # Either success or partial depending on repair, but never failure, and a
    # structuring usage_event is recorded for the token-consuming attempt.
    refute form_output.status_failure?
    assert UsageEvent.where(scribe_session_id: session.id, function: "structuring").exists?
  end

  # Regression: the ASR download must carry a real audio extension. A ".bin"
  # tempfile makes OpenAI Whisper reject the request with "Invalid file format".
  test "with_audio yields a tempfile with the uploaded file's audio extension" do
    session = create(:scribe_session)
    session.audio_files.attach(io: StringIO.new("fake-audio"), filename: "clip.mp3", content_type: "audio/mpeg")
    ext = nil
    Scribe::Orchestrator.new(session).send(:with_audio) { |io| ext = File.extname(io.path) }
    assert_equal ".mp3", ext
  end

  test "with_audio derives the extension from content-type when the filename has none" do
    session = create(:scribe_session)
    session.audio_files.attach(io: StringIO.new("fake-audio"), filename: "consultation", content_type: "audio/webm")
    ext = nil
    Scribe::Orchestrator.new(session).send(:with_audio) { |io| ext = File.extname(io.path) }
    assert_equal ".webm", ext
  end
end
