module Bench
  # Runs every selected structuring model over every structuring fixture through
  # the REAL stage (Scribe::StructuringStage with InlineField payloads, strict
  # schema, validation + one repair), and records per call: field-level accuracy
  # vs `expected`, latency, tokens, price-book cost, schema validity, errors.
  class StructuringBench
    def initialize(models:, fixtures:, runs: 1, io: $stdout)
      @models = models
      @fixtures = fixtures
      @runs = runs
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
        config = ModelConfig.for(model)

        @fixtures.each do |fx|
          fields = Scribe::InlineField.build_all(fx["fields"])
          @runs.times do |run|
            rows << run_one(model, config, fx, fields, run + 1)
            @io.print "."
          end
        end
        @io.puts " #{model.api_model_id}"
      end
      rows
    end

    private

    def run_one(model, config, fx, fields, run)
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      stage = Scribe::StructuringStage.new(
        config: config, fields: fields, context: {}, system_prompt: fx["system_prompt"]
      ).call(fx["transcript"])
      latency = elapsed_ms(started)
      score = Scorer.score(expected: fx["expected"], actual: stage.structured, rules: fx["scoring"])
      pricing = Metering::PriceBook.cost(function: :structuring, provider: config.provider_name,
                                         model: model.api_model_id, usage: stage.usage)
      AsrBench::Row.new(
        function: "structuring", model_id: model.id, model: model.api_model_id, provider: config.provider_name,
        fixture: fx["id"], language: fx["language"], run: run,
        ok: true, score: score[:accuracy], latency_ms: latency, audio_seconds: 0.0,
        cost: pricing[:cost], input_tokens: stage.usage&.input_tokens.to_i,
        output_tokens: stage.usage&.output_tokens.to_i,
        error: stage.valid ? nil : "schema: #{stage.errors.map { |e| e[:message] || e['message'] }.join('; ')}",
        output: { structured: stage.structured, fields: score[:fields].map(&:to_h) }
      )
    rescue StandardError => e
      AsrBench::Row.new(
        function: "structuring", model_id: model.id, model: model.api_model_id, provider: config.provider_name,
        fixture: fx["id"], language: fx["language"], run: run,
        ok: false, score: nil, latency_ms: elapsed_ms(started), audio_seconds: 0.0,
        cost: 0.0, input_tokens: 0, output_tokens: 0,
        error: "#{e.class}: #{e.message}", output: nil
      )
    end

    def elapsed_ms(start)
      ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - start) * 1000).round
    end
  end
end
