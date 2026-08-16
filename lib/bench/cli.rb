module Bench
  # Small helpers shared by the rake tasks (kept out of the task bodies so the
  # selection rules are testable).
  module Cli
    def self.list(var)
      ENV[var].to_s.split(",").map(&:strip).reject(&:empty?)
    end

    def self.runs
      [ ENV["RUNS"].to_i, 1 ].max
    end

    # MODELS unset/all -> every active model with the capability. Otherwise each
    # comma-separated term matches api_model_id, display_name, or a numeric id.
    def self.select_models(capability, terms: list("MODELS"))
      scope = AiModel.active.includes(:ai_provider).order(:id).select { |m| m.capability?(capability) }
      return scope if terms.empty? || terms == [ "all" ]

      scope.select do |m|
        terms.any? do |t|
          t == m.id.to_s || m.api_model_id.downcase.include?(t.downcase) || m.display_name.to_s.downcase.include?(t.downcase)
        end
      end
    end

    def self.announce(what, models, fixtures)
      puts "#{what} bench: #{models.size} model(s) x #{fixtures.size} fixture(s) x #{runs} run(s)"
      abort "No models selected (see bin/rails bench:models)" if models.empty?
      abort "No fixtures found under bench/fixtures" if fixtures.empty?
    end

    def self.report(function, rows)
      report = Bench::Report.new(function: function, rows: rows, label: ENV["LABEL"].presence)
      report.print
      path = report.write!
      puts
      puts "Report: #{Pathname.new(path).relative_path_from(Rails.root)} (+ .json)"
    end
  end
end
