module Llm
  module Adapters
    # Adapter for Sarvam AI's Speech-to-Text (strong on Indic languages +
    # code-mix). One REST endpoint, POST /speech-to-text, whose `mode` param on
    # the saaras:v3 model does transcribe / translate(->English) / codemix in a
    # single call — so the same config.asr_mode toggle that drives Whisper
    # transcribe/translate drives Sarvam too, and options[:sarvam_mode] can
    # request Sarvam-only modes (codemix/verbatim/translit).
    #
    # Auth is the "api-subscription-key" header. Multipart file upload; Sarvam
    # accepts WebM/OPUS/MP3/MP4/WAV/… natively, so no transcoding is needed. The
    # REST endpoint caps audio at ~30s — a natural fit for the incremental 3s
    # segment path (plan 022). Longer whole-file audio exceeds the cap and Sarvam
    # returns an error, which maps to a transient BadResponse so Caller falls
    # back to the configured fallback model (e.g. Whisper). Configure Sarvam WITH
    # a Whisper fallback and long audio degrades gracefully.
    #
    # Talks to Sarvam over Faraday directly (its API is not OpenAI-compatible).
    class Sarvam < Llm::Adapter
      SPEECH_TO_TEXT_PATH = "/speech-to-text".freeze
      SARVAM_MODES = %w[transcribe translate verbatim translit codemix].freeze

      # audio extension -> a content-type Sarvam's allowlist accepts. Sarvam
      # content-sniffs, but a correct multipart type avoids ambiguity.
      CONTENT_TYPES = {
        ".webm" => "audio/webm", ".ogg" => "audio/ogg", ".opus" => "audio/opus",
        ".mp3" => "audio/mpeg", ".m4a" => "audio/mp4", ".mp4" => "audio/mp4",
        ".wav" => "audio/wav", ".flac" => "audio/flac", ".aac" => "audio/aac"
      }.freeze

      def transcribe(audio_io, language: nil, mode: :transcribe, audio_seconds: 0, **_opts)
        started = monotonic

        payload = {
          file: file_part(audio_io),
          model: config.api_model_id,
          mode: sarvam_mode(mode),
          language_code: sarvam_language(language)
        }

        response = client.post(SPEECH_TO_TEXT_PATH, payload)
        body = response.body

        # A 200 whose body did not parse to a JSON object (e.g. an HTML error
        # page or gateway body) would otherwise raise TypeError on body["..."],
        # escaping the Llm::Error hierarchy. Route it through the transient
        # fallback machinery like a bad response.
        unless body.is_a?(Hash)
          raise Llm::BadResponse, "non-JSON response from Sarvam"
        end

        Llm::Result.new(
          text: body["transcript"],
          language: body["language_code"],
          model: config.api_model_id,
          provider: config.provider_name || config.provider_kind.to_s,
          usage: Llm::Usage.new(audio_seconds: audio_seconds),
          latency_ms: elapsed_ms(started),
          raw: body
        )
      rescue Faraday::Error => e
        raise map_transport_error(e)
      end

      private

      # An explicit options[:sarvam_mode] (codemix/verbatim/translit) wins; else
      # map the portable ASR mode. :translate -> Sarvam "translate" (-> English),
      # anything else -> "transcribe".
      def sarvam_mode(mode)
        override = config.options[:sarvam_mode].to_s
        return override if SARVAM_MODES.include?(override)

        mode.to_sym == :translate ? "translate" : "transcribe"
      end

      # Sarvam wants BCP-47 (e.g. "ml-IN"); "unknown" auto-detects. Pass a full
      # code through untouched, expand a bare ISO code, default to auto-detect.
      # The portable "auto" hint is auto-detect too (AsrStage already strips
      # it; guarded here as well because this is the method that would
      # otherwise fabricate the invalid "auto-IN").
      def sarvam_language(language)
        return "unknown" if language.blank? || language.to_s.casecmp?("auto")

        language.include?("-") ? language : "#{language}-IN"
      end

      def file_part(audio_io)
        path = audio_io.respond_to?(:path) ? audio_io.path.to_s : ""
        filename = path.empty? ? "audio.webm" : File.basename(path)
        content_type = CONTENT_TYPES[File.extname(filename).downcase] || "application/octet-stream"
        Faraday::Multipart::FilePart.new(audio_io, content_type, filename)
      end

      def client
        @client ||= Faraday.new(url: config.base_url) do |f|
          f.request :multipart
          f.request :url_encoded
          f.response :json
          f.response :raise_error
          f.options.timeout = config.request_timeout
          f.headers["api-subscription-key"] = config.api_key
        end
      end
    end
  end
end
