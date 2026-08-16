require "open3"
require "tmpdir"
require "base64"

module Bench
  # Turns an ASR fixture's dialogue into a synthetic clip at bench/audio/<id>.mp3:
  # one TTS call per turn (distinct doctor/patient voices), a short pause between
  # turns, concatenated with ffmpeg. English uses OpenAI TTS; Hindi / Malayalam /
  # Manglish use Sarvam Bulbul, which speaks Indic scripts natively. Force one
  # with TTS=openai|sarvam. Keys come from the provider rows (or ENV overrides,
  # see Bench::ModelConfig). Clips are committed so WER stays comparable across
  # runs; regenerate deliberately, not on every bench.
  class AudioGenerator
    OPENAI_VOICES = { "doctor" => "onyx", "patient" => "nova" }.freeze
    SARVAM_VOICES = { "doctor" => "abhilash", "patient" => "anushka" }.freeze
    PAUSE_SECONDS = 0.45

    def initialize(fixture, tts: ENV["TTS"].presence, io: $stdout)
      @fixture = fixture
      @tts = (tts || default_tts_for(fixture["language"])).to_sym
      @io = io
    end

    def call
      out = Fixtures.audio_path(@fixture["id"])
      FileUtils.mkdir_p(out.dirname)
      Dir.mktmpdir("bench-tts") do |dir|
        parts = @fixture["turns"].each_with_index.map do |turn, i|
          path = File.join(dir, format("turn-%02d.wav", i))
          File.binwrite(path, synthesize(turn["speaker"], turn["text"]))
          @io.print "."
          path
        end
        rate = sample_rate(parts.first)
        silence = File.join(dir, "silence.wav")
        run!("ffmpeg", "-y", "-v", "error", "-f", "lavfi", "-i", "anullsrc=r=#{rate}:cl=mono",
             "-t", PAUSE_SECONDS.to_s, silence)
        list = File.join(dir, "list.txt")
        File.write(list, parts.flat_map { |p| [ p, silence ] }.map { |p| "file '#{p}'" }.join("\n") + "\n")
        run!("ffmpeg", "-y", "-v", "error", "-f", "concat", "-safe", "0", "-i", list,
             "-ac", "1", "-ar", "24000", "-codec:a", "libmp3lame", "-q:a", "4", out.to_s)
      end
      @io.puts " #{out.relative_path_from(Rails.root)} (#{@tts}, #{AsrBench.duration_seconds(out)}s)"
      out
    end

    private

    def default_tts_for(language)
      %w[hi ml ta te kn bn gu mr pa od].include?(language.to_s) ? :sarvam : :openai
    end

    def synthesize(speaker, text)
      case @tts
      when :openai then openai_tts(OPENAI_VOICES.fetch(speaker, "alloy"), text)
      when :sarvam then sarvam_tts(SARVAM_VOICES.fetch(speaker, "anushka"), text)
      else raise ArgumentError, "unknown TTS #{@tts.inspect} (use openai or sarvam)"
      end
    end

    # POST /v1/audio/speech -> raw WAV bytes.
    def openai_tts(voice, text)
      provider = AiProvider.find_by!(name: "OpenAI")
      resp = Faraday.new(url: provider.base_url) { |f| f.options.timeout = 120 }.post("v1/audio/speech") do |req|
        req.headers["Authorization"] = "Bearer #{ModelConfig.api_key_for(provider)}"
        req.headers["Content-Type"] = "application/json"
        req.body = { model: "gpt-4o-mini-tts", voice: voice, input: text, response_format: "wav",
                     instructions: "Speak naturally at a normal conversational pace, like a person in a clinic." }.to_json
      end
      raise "OpenAI TTS failed (#{resp.status}): #{resp.body.to_s[0, 300]}" unless resp.status == 200

      resp.body
    end

    # POST /text-to-speech (Bulbul v2) -> { audios: [base64 wav] }.
    def sarvam_tts(speaker, text)
      provider = AiProvider.find_by!(name: "Sarvam")
      resp = Faraday.new(url: provider.base_url) { |f| f.options.timeout = 120 }.post("/text-to-speech") do |req|
        req.headers["api-subscription-key"] = ModelConfig.api_key_for(provider)
        req.headers["Content-Type"] = "application/json"
        req.body = { text: text, target_language_code: sarvam_language, speaker: speaker,
                     model: "bulbul:v2", pace: 1.0, speech_sample_rate: 22050 }.to_json
      end
      raise "Sarvam TTS failed (#{resp.status}): #{resp.body.to_s[0, 300]}" unless resp.status == 200

      Base64.decode64(JSON.parse(resp.body).fetch("audios").first)
    end

    def sarvam_language
      "#{@fixture['language']}-IN"
    end

    def sample_rate(wav_path)
      out, = Open3.capture2("ffprobe", "-v", "error", "-select_streams", "a:0",
                            "-show_entries", "stream=sample_rate", "-of", "csv=p=0", wav_path)
      out.strip.presence || "24000"
    end

    def run!(*cmd)
      _out, err, status = Open3.capture3(*cmd)
      raise "#{cmd.first} failed: #{err}" unless status.success?
    end
  end
end
