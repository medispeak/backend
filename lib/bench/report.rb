module Bench
  # Aggregates bench rows per model, prints a terminal table, and writes a
  # Markdown + JSON report to bench/results/<timestamp>-<function>.{md,json}.
  #
  # ASR score = WER (lower is better); structuring score = field accuracy
  # (higher is better). Latency is per call; cost is the price-book cost.
  class Report
    RESULTS_DIR = Rails.root.join("bench", "results")

    Summary = Struct.new(
      :model, :provider, :calls, :failures, :warnings, :score, :p50_ms, :p95_ms,
      :cost_total, :cost_unit, :tokens, :audio_seconds, keyword_init: true
    )

    def initialize(function:, rows:, io: $stdout, label: nil)
      @function = function.to_s
      @rows = rows
      @io = io
      @label = label
    end

    # Score is the mean over SUCCESSFUL calls only, so a model is never rewarded
    # for failing the hard fixtures: ranking is by failures first, then score,
    # then p50 latency. Unit cost is over successful (costed) calls only.
    def summaries
      @rows.group_by { |r| [ r.model, r.provider ] }.map do |(model, provider), rs|
        ok = rs.select(&:ok)
        scores = ok.filter_map(&:score)
        lat = ok.map(&:latency_ms).sort
        cost = ok.sum { |r| r.cost.to_f }
        audio_ok = ok.sum { |r| r.audio_seconds.to_f }
        Summary.new(
          model: model, provider: provider, calls: rs.size, failures: rs.count { |r| !r.ok },
          warnings: ok.count { |r| r.error },
          score: scores.empty? ? nil : (scores.sum / scores.size).round(4),
          p50_ms: percentile(lat, 0.5), p95_ms: percentile(lat, 0.95),
          cost_total: cost.round(6),
          cost_unit: asr? ? (audio_ok.positive? ? (cost / (audio_ok / 60.0)).round(6) : nil) : (ok.empty? ? nil : (cost / ok.size).round(6)),
          tokens: rs.sum { |r| r.input_tokens.to_i + r.output_tokens.to_i },
          audio_seconds: rs.sum { |r| r.audio_seconds.to_f }.round(1)
        )
      end.sort_by { |s| [ s.failures, s.score.nil? ? 1 : 0, asr? ? s.score.to_f : -s.score.to_f, s.p50_ms.to_i ] }
    end

    def print
      @io.puts
      @io.puts "== #{title} =="
      @io.puts table_text
      @io.puts
      @io.puts "score = #{asr? ? 'mean WER (lower is better)' : 'mean field accuracy (higher is better)'} over successful calls; " \
               "ranked by failures, then score, then p50; latency per call; " \
               "cost = #{asr? ? 'total / per audio-minute' : 'total / per call'} over successful calls (USD, price book)"
      failures = @rows.reject(&:ok)
      if failures.any?
        @io.puts
        @io.puts "Failures:"
        failures.each { |r| @io.puts "  - #{label(r)} / #{r.fixture} (run #{r.run}): #{r.error}" }
      end
      warnings = @rows.select { |r| r.ok && r.error }
      if warnings.any?
        @io.puts
        @io.puts "Warnings (call succeeded, output still invalid after the repair re-ask):"
        warnings.each { |r| @io.puts "  - #{label(r)} / #{r.fixture} (run #{r.run}): #{r.error}" }
      end
    end

    def write!(stamp: Time.now.utc.strftime("%Y%m%d-%H%M%S"))
      FileUtils.mkdir_p(RESULTS_DIR)
      base = RESULTS_DIR.join("#{stamp}-#{@function}")
      File.write("#{base}.md", markdown)
      File.write("#{base}.json", JSON.pretty_generate(
        function: @function, generated_at: Time.now.utc.iso8601, label: @label,
        summary: summaries.map(&:to_h), rows: @rows.map(&:to_h)
      ))
      "#{base}.md"
    end

    def markdown
      lines = [ "# Bench: #{title}", "", "Generated #{Time.now.utc.iso8601}#{@label ? " — #{@label}" : ''}", "",
                "| model | provider | calls | fail | warn | #{asr? ? 'WER' : 'accuracy'} | p50 ms | p95 ms | cost total | #{asr? ? '$/audio-min' : '$/call'} | tokens |",
                "|---|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|" ]
      summaries.each do |s|
        lines << "| #{s.model} | #{s.provider} | #{s.calls} | #{s.failures} | #{s.warnings} | #{fmt_score(s.score)} | #{s.p50_ms} | #{s.p95_ms} | #{fmt_cost(s.cost_total)} | #{fmt_cost(s.cost_unit)} | #{s.tokens} |"
      end
      lines << "" << "Score and unit cost are over successful calls; ranking is failures, then score, then p50. " \
               "warn = calls whose output was still schema-invalid after the repair re-ask (structuring)."
      lines << "" << "## Per fixture (#{asr? ? 'WER' : 'accuracy'})" << ""
      fixtures = @rows.map(&:fixture).uniq
      lines << "| model | " + fixtures.join(" | ") + " |"
      lines << "|---|" + fixtures.map { "---:" }.join("|") + "|"
      @rows.group_by { |r| label(r) }.each do |name, rs|
        cells = fixtures.map do |fx|
          sub = rs.select { |r| r.fixture == fx }
          scored = sub.select(&:ok).filter_map(&:score)
          mark = sub.any? { |r| r.ok && r.error } ? "*" : ""
          scored.empty? ? (sub.any? ? "ERR" : "-") : fmt_score(scored.sum / scored.size) + mark
        end
        lines << "| #{name} | " + cells.join(" | ") + " |"
      end
      failures = @rows.reject(&:ok)
      if failures.any?
        lines << "" << "## Failures" << ""
        failures.each { |r| lines << "- `#{label(r)}` / #{r.fixture} (run #{r.run}): #{md(r.error)}" }
      end
      warnings = @rows.select { |r| r.ok && r.error }
      if warnings.any?
        lines << "" << "## Warnings (output still invalid after repair; row marked * above)" << ""
        warnings.each { |r| lines << "- `#{label(r)}` / #{r.fixture} (run #{r.run}): #{md(r.error)}" }
      end
      if asr?
        lines << "" << "## Transcripts" << ""
        @rows.select(&:ok).group_by(&:fixture).each do |fx, rs|
          lines << "### #{fx}" << ""
          rs.each { |r| lines << "- **#{label(r)}** (WER #{fmt_score(r.score)}): #{md(r.output)}" }
          lines << ""
        end
      end
      lines.join("\n") + "\n"
    end

    private

    def asr?
      @function == "asr"
    end

    def title
      "#{@function} — #{@rows.map(&:model_id).uniq.size} model(s), #{@rows.map(&:fixture).uniq.size} fixture(s), #{@rows.size} call(s)"
    end

    # "model" when the api_model_id is unique across providers, else
    # "model (provider)" so two rows with the same id never merge.
    def label(row)
      providers = @rows.select { |r| r.model == row.model }.map(&:provider).uniq
      providers.size > 1 ? "#{row.model} (#{row.provider})" : row.model
    end

    # Pipes and newlines would break markdown table cells / list items.
    def md(text)
      text.to_s.gsub(/\s+/, " ").gsub("|", "\\|")
    end

    def table_text
      header = [ "model", "provider", "calls", "fail", "warn", asr? ? "WER" : "acc", "p50 ms", "p95 ms", "cost", asr? ? "$/min" : "$/call" ]
      data = summaries.map do |s|
        [ s.model, s.provider, s.calls, s.failures, s.warnings, fmt_score(s.score), s.p50_ms, s.p95_ms, fmt_cost(s.cost_total), fmt_cost(s.cost_unit) ].map(&:to_s)
      end
      widths = ([ header ] + data).transpose.map { |col| col.map(&:length).max }
      fmt = ->(cells) { cells.each_with_index.map { |c, i| i < 2 ? c.ljust(widths[i]) : c.rjust(widths[i]) }.join("  ") }
      ([ fmt.call(header), widths.map { |w| "-" * w }.join("  ") ] + data.map { |d| fmt.call(d) }).join("\n")
    end

    def percentile(sorted, p)
      return nil if sorted.empty?

      sorted[[ (sorted.size * p).ceil - 1, 0 ].max]
    end

    def fmt_score(v)
      v.nil? ? "-" : format("%.3f", v)
    end

    def fmt_cost(v)
      v.nil? ? "-" : format("%.5f", v)
    end
  end
end
