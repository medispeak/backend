module Llm
  module Adapters
    # Adapter for Microsoft's MAI-Transcribe models (e.g. mai-transcribe-1.5)
    # served by an Azure AI Foundry Speech resource's LLM Speech API:
    # POST {base_url}/speechtotext/transcriptions:transcribe?api-version=…
    # Multipart with an `audio` file part and a `definition` JSON part; auth is
    # the "Ocp-Apim-Subscription-Key" header. Formats verified live 2026-08-23:
    # WAV, Ogg/Opus, MP3, FLAC accepted; WebM and M4A/AAC rejected with 400
    # invalid_audio (despite the generic LLM Speech docs listing WebM). The
    # browser recorder emits WebM/Opus — same codec, unaccepted container — so
    # when ffmpeg is bundled the adapter remuxes those to Ogg before posting
    # (Llm::AudioConverter) and both the 3s segment path and whole-file audio
    # reach MAI directly; without ffmpeg the original bytes go out and the 400
    # drives the normal fallback.
    #
    # Omitting `locales` keeps the model's multilingual auto-detect; a language
    # hint is sent as a bare ISO-639 code ("ml-IN" -> "ml"). The portable
    # :translate mode maps to enhanced task "translate" targeting English
    # (parity with Whisper). mai-transcribe-1.5 extras ride on assignment
    # options: phrase_list (entity biasing — drug/clinician names) and
    # transcribe_style ("verbatim" keeps fillers/disfluencies).
    #
    # Talks to Azure over Faraday directly (this surface is not OpenAI-compatible).
    class AzureFoundry < Llm::Adapter
      TRANSCRIBE_PATH = "/speechtotext/transcriptions:transcribe".freeze
      # The preview version the LLM Speech API is pinned to today; overridable
      # via options[:azure_api_version] so an Azure version bump is a config
      # edit. Namespaced like sarvam_mode because ConfigResolver forwards the
      # primary's options to the fallback config — a bare api_version key would
      # be picked up by an openai_compatible fallback and 404 it.
      DEFAULT_API_VERSION = "2025-10-15".freeze

      # Containers the MAI backend ingests as-is (verified live); everything
      # else convertible goes through Llm::AudioConverter first.
      ACCEPTED_EXTENSIONS = %w[.wav .ogg .opus .mp3 .flac].freeze

      # audio extension -> a content-type on Azure's accepted-format list.
      CONTENT_TYPES = {
        ".webm" => "audio/webm", ".ogg" => "audio/ogg", ".opus" => "audio/opus",
        ".mp3" => "audio/mpeg", ".m4a" => "audio/mp4", ".mp4" => "audio/mp4",
        ".wav" => "audio/wav", ".flac" => "audio/flac", ".aac" => "audio/aac",
        ".wma" => "audio/x-ms-wma", ".amr" => "audio/amr"
      }.freeze

      def transcribe(audio_io, language: nil, mode: :transcribe, audio_seconds: 0, **_opts)
        started = monotonic

        converted = maybe_convert(audio_io)
        payload = { audio: file_part(converted || audio_io), definition: definition_json(language, mode) }
        response = client.post("#{TRANSCRIBE_PATH}?api-version=#{api_version}", payload)
        body = response.body

        # A 200 that is not a transcription payload (HTML gateway page, an
        # unexpected JSON shape) would surface as an empty transcript; route it
        # through the transient fallback machinery instead. combinedPhrases is
        # always an array on a real response — it is [] for pure silence.
        unless body.is_a?(Hash) && body["combinedPhrases"].is_a?(Array)
          raise Llm::BadResponse, "non-transcription response from Azure Foundry"
        end

        Llm::Result.new(
          text: Array(body["combinedPhrases"]).filter_map { |p| p["text"] if p.is_a?(Hash) }.join("\n"),
          language: detected_locale(body),
          model: config.api_model_id,
          provider: config.provider_name || config.provider_kind.to_s,
          usage: Llm::Usage.new(audio_seconds: usage_seconds(audio_seconds, body)),
          latency_ms: elapsed_ms(started),
          raw: body
        )
      rescue Faraday::Error => e
        raise map_transport_error(e)
      ensure
        converted&.close!
      end

      private

      def maybe_convert(audio_io)
        ext = source_extension(audio_io)
        return nil if ext.empty? || ACCEPTED_EXTENSIONS.include?(ext)
        return nil unless Llm::AudioConverter.convertible?(ext)

        Llm::AudioConverter.to_ogg(audio_io, ext)
      end

      def source_extension(audio_io)
        path = audio_io.respond_to?(:path) ? audio_io.path.to_s : ""
        File.extname(path).downcase
      end

      def definition_json(language, mode)
        enhanced = { enabled: true, model: config.api_model_id }
        if mode.to_sym == :translate
          enhanced[:task] = "translate"
          enhanced[:targetLanguage] = "en"
        end
        style = config.options[:transcribe_style].to_s
        enhanced[:transcribeStyle] = style if style.present?

        definition = { enhancedMode: enhanced }
        locale = bare_locale(language)
        definition[:locales] = [ locale ] if locale
        phrases = Array(config.options[:phrase_list])
        definition[:phraseList] = { phrases: phrases } if phrases.any?
        definition.to_json
      end

      # Azure reports locale per phrase; take the first. Tolerates a malformed
      # phrases field — locale is advisory, never worth a TypeError that would
      # escape the Llm::Error hierarchy and skip fallback on a good transcript.
      def detected_locale(body)
        first = Array(body["phrases"]).first
        first.is_a?(Hash) ? first["locale"] : nil
      end

      # MAI models take bare ISO-639 codes ("ml", never "ml-IN"); nil and the
      # portable "auto" hint keep multilingual auto-detect (AsrStage already
      # strips "auto"; guarded here as well like the Sarvam adapter).
      def bare_locale(language)
        return nil if language.blank? || language.to_s.casecmp?("auto")

        language.to_s.split("-").first.downcase
      end

      # ASR is billed per minute but callers cannot always measure duration;
      # Azure reports it, so prefer that over metering zero seconds.
      def usage_seconds(audio_seconds, body)
        return audio_seconds if audio_seconds.to_f.positive?

        body["durationMilliseconds"].to_f / 1000
      end

      def api_version
        CGI.escape(config.options[:azure_api_version].presence || DEFAULT_API_VERSION)
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
          f.headers["Ocp-Apim-Subscription-Key"] = config.api_key
        end
      end
    end
  end
end
