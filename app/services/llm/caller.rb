module Llm
  # Owns the try-primary-then-fallback policy for a single function call. This
  # is the SINGLE owner of fallback (UsageRecorder, added later, will be invoked
  # here once per physical attempt and stays a pure meter with no fallback logic).
  #
  # Transient errors (Timeout/RateLimited/BadResponse) trigger one fallback
  # attempt if a fallback Config is set. Refusals are NOT retried.
  class Caller
    TRANSIENT = [ Llm::Timeout, Llm::RateLimited, Llm::BadResponse ].freeze

    def self.transcribe(config, *args, **kwargs)
      new(config).run(:transcribe, *args, **kwargs)
    end

    def self.structure(config, *args, **kwargs)
      new(config).run(:structure, *args, **kwargs)
    end

    # documents are passed as in-memory bytes (not IOs), so a fallback attempt
    # re-sends them without any rewind concern.
    def self.ocr(config, *args, **kwargs)
      new(config).run(:ocr, *args, **kwargs)
    end

    def initialize(config)
      @config = config
    end

    def run(method, *args, **kwargs)
      attempt(@config, method, *args, **kwargs)
    rescue *TRANSIENT => e
      raise e unless @config.fallback

      rewind_ios(args)
      result = attempt(@config.fallback, method, *args, **kwargs)

      # Carry the abandoned attempt forward instead of dropping it. A truncated
      # or empty 200 is a BILLED response — the provider counted those tokens —
      # and falling back means the orchestrator only ever sees the success. Left
      # unattached, the primary's spend is recorded nowhere at all, which is the
      # exact leak the failed-attempt metering exists to close. Only errors that
      # actually carry usage are worth passing on; a timeout billed nothing.
      if result.is_a?(Llm::Result) && e.respond_to?(:billable?) && e.billable?
        result.discarded_attempts = result.discarded + [ e ]
      end
      result
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
