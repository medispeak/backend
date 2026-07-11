module Llm
  # Owns the try-primary-then-fallback policy for a single function call. This
  # is the SINGLE owner of fallback (UsageRecorder, added later, will be invoked
  # here once per physical attempt and stays a pure meter with no fallback logic).
  #
  # Transient errors (Timeout/RateLimited/BadResponse) trigger one fallback
  # attempt if a fallback Config is set. Refusals are NOT retried.
  class Caller
    TRANSIENT = [Llm::Timeout, Llm::RateLimited, Llm::BadResponse].freeze

    def self.transcribe(config, *args, **kwargs)
      new(config).run(:transcribe, *args, **kwargs)
    end

    def self.structure(config, *args, **kwargs)
      new(config).run(:structure, *args, **kwargs)
    end

    def initialize(config)
      @config = config
    end

    def run(method, *args, **kwargs)
      attempt(@config, method, *args, **kwargs)
    rescue *TRANSIENT => e
      raise e unless @config.fallback

      rewind_ios(args)
      attempt(@config.fallback, method, *args, **kwargs)
    end

    private

    def attempt(config, method, *args, **kwargs)
      Llm::Registry.adapter_for(config).public_send(method, *args, **kwargs)
    end

    # The primary attempt reads any audio IO to EOF (multipart upload), so the
    # fallback would otherwise post a 0-byte file — e.g. Sarvam rejecting >30s
    # audio AFTER reading it, then Whisper receiving an exhausted IO. Rewind
    # every positional IO before the fallback attempt.
    def rewind_ios(args)
      args.each { |a| a.rewind if a.respond_to?(:rewind) }
    rescue IOError
      # A closed/unrewindable IO: let the fallback attempt surface the real error.
    end
  end
end
