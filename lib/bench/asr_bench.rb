require "open3"

module Bench
  # Runs every selected ASR model over every ASR fixture through the REAL
  # pipeline stage (Scribe::AsrStage -> Llm::Caller -> adapter), and records
  # per call: WER vs the fixture's reference, wall-clock latency, audio seconds,
  # price-book cost, and any error. Sequential on purpose so latencies are
  # comparable. Returns an Array of row Hashes; Bench::Report aggregates them.
  class AsrBench
    Row = Struct.new(
      :function, :model_id, :model, :provider, :fixture, :language, :run,
      :ok, :score, :latency_ms, :audio_seconds, :cost, :input_tokens, :output_tokens,
      :error, :output, keyword_init: true
    )

    # language_hint: false sends no language to any model (pure auto-detect),
    # which mirrors clients that send no language_hint / "auto".
    # duration_for: callable(path) -> seconds; defaults to ffprobe (injectable for tests).
    def initialize(models:, fixtures:, runs: 1, mode: :transcribe, options: {}, language_hint: true,
                   duration_for: self.class.method(:duration_seconds), io: $stdout)
      @models = models
      @fixtures = fixtures
      @runs = runs
      @mode = mode
      @options = options
      @language_hint = language_hint
      @duration_for = duration_for
      @io = io
    end

    def call
      rows = []
      @models.each do |model|
        provider = model.ai_provider
        if ModelConfig.missing_key?(provider)
          @io.puts "  ~ skipping #{model.api_model_id}: no API key for provider #{provider.name}"
          next
        end
        config = ModelConfig.for(model, options: @options)

        @fixtures.each do |fx|
          unless File.exist?(fx["audio_path"])
            @io.puts "  ~ skipping #{fx['id']}: no audio at #{fx['audio_path']} (run bench:audio)"
            next
          end
          duration = @duration_for.call(fx["audio_path"])
          @runs.times do |run|
            rows << run_one(model, config, fx, duration, run + 1)
            @io.print "."
          end
        end
        @io.puts " #{model.api_model_id}"
      end
      rows
    end

    private

    def run_one(model, config, fx, duration, run)
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      result = File.open(fx["audio_path"], "rb") do |io|
        Scribe::AsrStage.new(config: config).call(
          io, language: (@language_hint ? fx["language"] : nil), mode: @mode, audio_seconds: duration
        )
      end
      latency = elapsed_ms(started)
      wer = Wer.compute(fx["reference"], result.text)
      pricing = Metering::PriceBook.cost(function: :asr, provider: config.provider_name,
                                         model: model.api_model_id, usage: result.usage)
      Row.new(
        function: "asr", model_id: model.id, model: model.api_model_id, provider: config.provider_name,
        fixture: fx["id"], language: fx["language"], run: run,
        ok: true, score: wer[:wer], latency_ms: latency, audio_seconds: duration,
        cost: pricing[:cost], input_tokens: result.usage&.input_tokens.to_i,
        output_tokens: result.usage&.output_tokens.to_i,
        error: nil, output: result.text.to_s
      )
    rescue StandardError => e
      Row.new(
        function: "asr", model_id: model.id, model: model.api_model_id, provider: config.provider_name,
        fixture: fx["id"], language: fx["language"], run: run,
        ok: false, score: nil, latency_ms: elapsed_ms(started), audio_seconds: duration,
        cost: 0.0, input_tokens: 0, output_tokens: 0,
        error: "#{e.class}: #{e.message}", output: nil
      )
    end

    def elapsed_ms(start)
      ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - start) * 1000).round
    end

    # Loud on purpose: a silent 0.0 would run the whole paid matrix and report
    # $0 for every per-minute-priced model.
    def self.duration_seconds(path)
      out, err, status = Open3.capture3(
        "ffprobe", "-v", "error", "-show_entries", "format=duration", "-of", "csv=p=0", path.to_s
      )
      raise "ffprobe could not read #{path}: #{err.strip}" unless status.success?

      out.strip.to_f.round(3)
    rescue Errno::ENOENT
      raise "ffprobe is required to measure clip duration (brew install ffmpeg)"
    end
  end
end
