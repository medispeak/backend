module Llm
  # Maps a Config's provider_kind to its adapter class. Adapter classes are
  # referenced by name so Zeitwerk autoloads them lazily under Rails; in
  # standalone tests the constant is already loaded.
  module Registry
    ADAPTERS = {
      openai_compatible: "Llm::Adapters::OpenaiCompatible"
      # anthropic: "Llm::Adapters::Anthropic"  # added in a later phase
    }.freeze

    def self.adapter_for(config)
      class_name = ADAPTERS.fetch(config.provider_kind) do
        raise Llm::Error, "No adapter registered for provider kind: #{config.provider_kind.inspect}"
      end
      resolve(class_name).new(config)
    end

    def self.resolve(class_name)
      class_name.split("::").inject(Object) { |mod, const| mod.const_get(const) }
    end
  end
end
