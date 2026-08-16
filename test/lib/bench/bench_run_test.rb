require "test_helper"

# End-to-end through the real stages with stubbed provider HTTP: proves the
# runners, scoring, price book and report compose without a network.
class BenchRunTest < ActiveSupport::TestCase
  setup do
    @provider = create(:ai_provider, name: "OpenAI", kind: "openai_compatible",
                                     base_url: "https://api.openai.com/", api_key: "sk-test")
    @asr = create(:ai_model, ai_provider: @provider, api_model_id: "whisper-1",
                             capabilities: { "accepts_audio" => true, "can_transcribe" => true })
    @llm = create(:ai_model, ai_provider: @provider, api_model_id: "gpt-4.1-mini",
                             capabilities: { "can_structure" => true, "supports_json_schema" => true })
    AudioModelPrice.create!(provider: "OpenAI", model: "whisper-1", price_per_minute: 0.006, currency: "USD")
    ModelPrice.create!(provider: "OpenAI", model: "gpt-4.1-mini", input_per_million: 0.4, output_per_million: 1.6, currency: "USD")
    @io = StringIO.new
  end

  test "asr bench scores WER, latency and cost per model, and reports" do
    stub_request(:post, "https://api.openai.com/v1/audio/transcriptions")
      .to_return(status: 200, headers: { "Content-Type" => "application/json" },
                 body: { text: "hello doctor i have fever" }.to_json)
    Dir.mktmpdir do |dir|
      audio = File.join(dir, "clip.mp3"); File.binwrite(audio, "not-really-audio")
      fx = { "id" => "t1", "language" => "en", "reference" => "Hello doctor, I have a fever.", "audio_path" => audio }

      rows = Bench::AsrBench.new(models: [ @asr ], fixtures: [ fx ], io: @io, duration_for: ->(_) { 6.0 }).call
      assert_equal 1, rows.size
      row = rows.first
      assert row.ok, row.error
      assert_in_delta 1.0 / 6, row.score, 0.001, "one deleted word ('a') out of 6"
      assert_operator row.latency_ms, :>=, 0
      assert_equal "OpenAI", row.provider
      assert_equal 6.0, row.audio_seconds
      assert_in_delta 0.0006, row.cost, 1e-6, "6s at $0.006/min"

      report = Bench::Report.new(function: :asr, rows: rows, io: @io)
      s = report.summaries.first
      assert_equal "whisper-1", s.model
      assert_equal 0, s.failures
      assert_in_delta 0.006, s.cost_unit, 1e-6, "$/audio-min equals the price-book rate"
      assert_includes report.markdown, "| whisper-1 | OpenAI | 1 | 0 | 0 |"
    end
  end

  test "report ranks by failures first and computes $/min over successful calls only" do
    stub_request(:post, "https://api.openai.com/v1/audio/transcriptions")
      .to_return({ status: 200, headers: { "Content-Type" => "application/json" }, body: { text: "hi" }.to_json },
                 { status: 400, body: { error: { message: "nope" } }.to_json })
    other = create(:ai_model, ai_provider: @provider, api_model_id: "gpt-4o-transcribe",
                              capabilities: { "accepts_audio" => true, "can_transcribe" => true })
    AudioModelPrice.create!(provider: "OpenAI", model: "gpt-4o-transcribe", price_per_minute: 0.006, currency: "USD")
    Dir.mktmpdir do |dir|
      audio = File.join(dir, "clip.mp3"); File.binwrite(audio, "x")
      fx = { "id" => "t1", "language" => "en", "reference" => "hi", "audio_path" => audio }
      # whisper-1 succeeds (WER 0), gpt-4o-transcribe fails its only call
      rows = Bench::AsrBench.new(models: [ @asr, other ], fixtures: [ fx ], io: @io, duration_for: ->(_) { 60.0 }).call
      report = Bench::Report.new(function: :asr, rows: rows, io: @io)
      names = report.summaries.map(&:model)
      assert_equal %w[whisper-1 gpt-4o-transcribe], names
      failed = report.summaries.last
      assert_equal 1, failed.failures
      assert_nil failed.cost_unit, "no successful call -> no unit cost, not 0"
    end
  end

  test "asr bench records provider failures as rows instead of aborting" do
    stub_request(:post, "https://api.openai.com/v1/audio/transcriptions").to_return(status: 500, body: "boom")
    Dir.mktmpdir do |dir|
      audio = File.join(dir, "clip.mp3"); File.binwrite(audio, "x")
      fx = { "id" => "t1", "language" => "en", "reference" => "hi", "audio_path" => audio }
      rows = Bench::AsrBench.new(models: [ @asr ], fixtures: [ fx ], io: @io, duration_for: ->(_) { 3.0 }).call
      assert_equal 1, rows.size
      assert_not rows.first.ok
      assert_match(/Llm::/, rows.first.error)
    end
  end

  test "structuring bench scores fields through the real stage" do
    stub_request(:post, "https://api.openai.com/v1/chat/completions")
      .to_return(status: 200, headers: { "Content-Type" => "application/json" },
                 body: { choices: [ { finish_reason: "stop", message: { content: { systolic_bp: 130, symptoms: [ "Fever" ], note: "pt has fever" }.to_json } } ],
                         usage: { prompt_tokens: 120, completion_tokens: 20 } }.to_json)
    fx = {
      "id" => "s1", "language" => "en", "transcript" => "BP one thirty over eighty, fever since yesterday.",
      "fields" => [
        { "key" => "systolic_bp", "label" => "Systolic BP", "type" => "number", "minimum" => 50, "maximum" => 250 },
        { "key" => "symptoms", "label" => "Symptoms", "type" => "multi_select", "enum" => [ "Fever", "Cough" ] },
        { "key" => "note", "label" => "Note", "type" => "string" }
      ],
      "expected" => { "systolic_bp" => 130, "symptoms" => [ "Fever" ], "note" => "fever" },
      "scoring" => { "note" => "contains:fever" }
    }
    rows = Bench::StructuringBench.new(models: [ @llm ], fixtures: [ fx ], io: @io).call
    row = rows.first
    assert row.ok, row.error
    assert_equal 1.0, row.score
    assert_equal 140, row.input_tokens + row.output_tokens
    assert_operator row.cost, :>, 0
    assert_includes Bench::Report.new(function: :structuring, rows: rows, io: @io).markdown, "| gpt-4.1-mini | OpenAI | 1 | 0 | 0 | 1.000 |"
  end

  test "structuring rows that stay schema-invalid after repair are surfaced as warnings, not hidden" do
    stub_request(:post, "https://api.openai.com/v1/chat/completions")
      .to_return(status: 200, headers: { "Content-Type" => "application/json" },
                 body: { choices: [ { finish_reason: "stop", message: { content: { systolic_bp: 999 }.to_json } } ],
                         usage: { prompt_tokens: 10, completion_tokens: 2 } }.to_json)
    fx = { "id" => "s1", "language" => "en", "transcript" => "BP nine ninety nine",
           "fields" => [ { "key" => "systolic_bp", "label" => "Systolic BP", "type" => "number", "minimum" => 50, "maximum" => 250 } ],
           "expected" => { "systolic_bp" => 999 } }
    rows = Bench::StructuringBench.new(models: [ @llm ], fixtures: [ fx ], io: @io).call
    assert rows.first.ok
    assert_match(/schema:/, rows.first.error)
    assert_equal 24, rows.first.input_tokens + rows.first.output_tokens, "repair call usage is included"
    report = Bench::Report.new(function: :structuring, rows: rows, io: @io)
    assert_equal 1, report.summaries.first.warnings
    assert_includes report.markdown, "## Warnings"
    assert_includes report.markdown, "1.000* |"
    report.print
    assert_match(/Warnings \(call succeeded/, @io.string)
  end

  test "models with a placeholder key are skipped with a note" do
    # A provider with no ENV override mapping, so the row's placeholder is what counts.
    local = create(:ai_provider, name: "Self-hosted Whisper", kind: "openai_compatible",
                                 base_url: "http://localhost:8000/", api_key: "not-needed")
    model = create(:ai_model, ai_provider: local, api_model_id: "local-llm",
                              capabilities: { "can_structure" => true })
    rows = Bench::StructuringBench.new(models: [ model ], fixtures: [ { "id" => "s", "fields" => [], "transcript" => "", "expected" => {} } ], io: @io).call
    assert_empty rows
    assert_match(/skipping local-llm: no API key/, @io.string)
  end

  test "an ENV key overrides a placeholder on the provider row" do
    @provider.update!(api_key: "set-your-openai-key")
    with_env("OPENAI_ACCESS_TOKEN" => "env-token") do
      assert_equal "env-token", Bench::ModelConfig.api_key_for(@provider)
      assert_not Bench::ModelConfig.missing_key?(@provider)
    end
    with_env("OPENAI_ACCESS_TOKEN" => nil) do
      assert Bench::ModelConfig.missing_key?(@provider), "placeholder row + no ENV -> missing"
    end
  end

  private

  # Never assert on ambient secrets: pin ENV for the block, then restore.
  def with_env(pairs)
    saved = pairs.keys.to_h { |k| [ k, ENV[k] ] }
    pairs.each { |k, v| v.nil? ? ENV.delete(k) : ENV[k] = v }
    yield
  ensure
    saved.each { |k, v| v.nil? ? ENV.delete(k) : ENV[k] = v }
  end

  test "Cli.select_models filters by capability and by id / substring" do
    assert_equal [ @asr ], Bench::Cli.select_models(:can_transcribe, terms: [])
    assert_equal [ @llm ], Bench::Cli.select_models(:can_structure, terms: [ "4.1" ])
    assert_equal [ @asr ], Bench::Cli.select_models(:can_transcribe, terms: [ @asr.id.to_s ])
    assert_empty Bench::Cli.select_models(:can_transcribe, terms: [ "nope" ])
  end
end
