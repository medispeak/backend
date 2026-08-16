# Model benchmark: run any set of ASR / structuring models over the synthetic
# fixtures in bench/fixtures and get accuracy, latency and cost per model.
#
#   bin/rails bench:asr                       # every active can_transcribe model
#   bin/rails bench:structuring               # every active can_structure model
#   bin/rails bench:all
#   MODELS=whisper,saaras bin/rails bench:asr # substring match on api_model_id / display name
#   FIXTURES=en_fever_followup,hi_bp_checkup  # subset of fixture ids
#   RUNS=3                                    # repeat each call (latency stability)
#   MODE=translate                            # ASR mode (default transcribe)
#   LANGUAGE_HINT=false                       # send no language (auto-detect) instead of the fixture's
#   LABEL="after switching to X"              # free-text label stored in the report
#   bin/rails bench:audio                     # (re)generate synthetic clips via TTS
#
# Keys come from the AiProvider rows; override per provider with
# OPENROUTER_API_KEY / OPENAI_ACCESS_TOKEN / ANTHROPIC_API_KEY / SARVAM_API_KEY.
# Reports land in bench/results/<timestamp>-<function>.{md,json}.
namespace :bench do
  desc "Benchmark ASR models over bench/fixtures/asr (WER, latency, cost)"
  task asr: :environment do
    models = Bench::Cli.select_models(:can_transcribe)
    fixtures = Bench::Fixtures.asr(only: Bench::Cli.list("FIXTURES"))
    Bench::Cli.announce("ASR", models, fixtures)
    rows = Bench::AsrBench.new(models: models, fixtures: fixtures, runs: Bench::Cli.runs,
                               mode: (ENV["MODE"].presence || "transcribe").to_sym,
                               language_hint: ENV["LANGUAGE_HINT"].to_s != "false").call
    Bench::Cli.report(:asr, rows)
  end

  desc "Benchmark structuring models over bench/fixtures/structuring (field accuracy, latency, cost)"
  task structuring: :environment do
    models = Bench::Cli.select_models(:can_structure)
    fixtures = Bench::Fixtures.structuring(only: Bench::Cli.list("FIXTURES"))
    Bench::Cli.announce("Structuring", models, fixtures)
    rows = Bench::StructuringBench.new(models: models, fixtures: fixtures, runs: Bench::Cli.runs).call
    Bench::Cli.report(:structuring, rows)
  end

  desc "Run both benchmarks"
  task all: %i[asr structuring]

  desc "Generate synthetic audio clips for the ASR fixtures via TTS (FIXTURES=..., TTS=openai|sarvam)"
  task audio: :environment do
    Bench::Fixtures.asr(only: Bench::Cli.list("FIXTURES")).each do |fx|
      print "#{fx['id']} "
      Bench::AudioGenerator.new(fx).call
    end
  end

  desc "List benchable models and whether their provider has a usable key"
  task models: :environment do
    AiModel.active.includes(:ai_provider).order(:id).each do |m|
      caps = %i[can_transcribe can_structure].select { |c| m.capability?(c) }.join(",")
      key = Bench::ModelConfig.missing_key?(m.ai_provider) ? "NO KEY" : "key ok"
      puts format("%-4d %-52s %-14s %-28s %s", m.id, m.api_model_id, m.ai_provider.name, caps, key)
    end
  end
end
