require "tempfile"

module Llm
  # ffmpeg-backed conversion to Ogg for providers that reject a source
  # container. Opus-in-WebM is a pure stream copy (no decode, ~tens of ms);
  # the AAC family is a real transcode. Never raises: no binary, a failed run,
  # or garbage input all return nil, and the caller sends the original bytes —
  # the provider's own rejection then drives the normal fallback machinery.
  #
  # The binary is resolved per call: FFMPEG_BIN, then the vendored static
  # build (production installs it via the app-spec build command), then PATH.
  module AudioConverter
    module_function

    COPY_EXTENSIONS = %w[.webm].freeze
    TRANSCODE_EXTENSIONS = %w[.m4a .mp4 .aac .wma .amr].freeze

    def convertible?(extension)
      ext = extension.to_s.downcase
      COPY_EXTENSIONS.include?(ext) || TRANSCODE_EXTENSIONS.include?(ext)
    end

    def available?
      !binary.nil?
    end

    def binary
      candidates = [ ENV["FFMPEG_BIN"] ]
      candidates << Rails.root.join("vendor/ffmpeg/ffmpeg").to_s if defined?(Rails) && Rails.respond_to?(:root) && Rails.root
      found = candidates.compact.find { |path| File.executable?(path) }
      found || path_binary
    end

    # Returns a rewound .ogg Tempfile (caller closes), or nil. Reads the
    # source IO to EOF — Llm::Caller rewinds positional IOs before a fallback
    # attempt, so that contract is already covered.
    def to_ogg(io, extension)
      bin = binary
      return nil if bin.nil?

      ext = extension.to_s.downcase
      codec = COPY_EXTENSIONS.include?(ext) ? [ "-c:a", "copy" ] : [ "-c:a", "libopus", "-b:a", "32k" ]

      src = Tempfile.new([ "asr_src", ext ])
      dst = Tempfile.new([ "asr_ogg", ".ogg" ])
      begin
        src.binmode
        src.write(io.read)
        src.flush

        ok = system(bin, "-y", "-loglevel", "error", "-i", src.path, *codec, dst.path,
                    out: File::NULL, err: File::NULL)
        unless ok && File.size(dst.path).positive?
          Rails.logger.warn("Llm::AudioConverter: ffmpeg failed for #{ext}") if defined?(Rails) && Rails.logger
          dst.close!
          return nil
        end

        dst.rewind
        dst
      rescue StandardError
        dst.close!
        nil
      ensure
        src.close!
      end
    end

    def path_binary
      ENV["PATH"].to_s.split(File::PATH_SEPARATOR).map { |dir| File.join(dir, "ffmpeg") }
                 .find { |path| File.executable?(path) }
    end
  end
end
