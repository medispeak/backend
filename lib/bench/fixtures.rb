module Bench
  # Loads bench fixtures from bench/fixtures/{asr,structuring}/*.json.
  #
  # ASR fixture:  { id, title, language, code_mix, turns: [{speaker, text}] }
  #   reference transcript = turns' text joined; audio at bench/audio/<id>.mp3
  # Structuring fixture: { id, title, language, system_prompt, transcript,
  #   fields: [InlineField payloads], expected: {key => value}, scoring: {key => rule} }
  module Fixtures
    ROOT = Rails.root.join("bench")

    def self.asr(only: nil)
      load_dir("asr", only).map do |h|
        h.merge(
          "reference" => Array(h["turns"]).map { |t| t["text"] }.join(" "),
          "audio_path" => audio_path(h["id"])
        )
      end
    end

    def self.structuring(only: nil)
      load_dir("structuring", only)
    end

    def self.audio_path(id)
      ROOT.join("audio", "#{id}.mp3")
    end

    def self.load_dir(kind, only)
      files = Dir[ROOT.join("fixtures", kind, "*.json").to_s].sort
      wanted = Array(only).map(&:to_s).reject(&:empty?)
      files.filter_map do |path|
        h = JSON.parse(File.read(path))
        next if wanted.any? && !wanted.include?(h["id"])

        h
      end
    end
  end
end
