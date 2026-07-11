module Llm
  # Resolves an Llm::Config for a function (asr/structuring/combined) using the
  # most-specific ModelAssignment: Page -> Account -> System. Falls back to the
  # ENV-based DefaultConfigProvider when no assignment exists.
  #
  # Decryption of the provider key is deferred to a lazy api_key_resolver, so
  # this resolver does not need encryption configured to be unit-reasoned about.
  class ConfigResolver
    def self.call(function:, page: nil, account: nil)
      new(function: function, page: page, account: account).call
    end

    def initialize(function:, page: nil, account: nil)
      @function = function.to_sym
      @page = page
      @account = account
    end

    def call
      assignment = find_assignment
      return Llm::DefaultConfigProvider.call(function: @function) unless assignment

      config_for(assignment.ai_model, assignment.options, fallback_model: assignment.fallback_ai_model)
    end

    private

    def find_assignment
      scopes.each do |scope_type, scope_id|
        assignment = ModelAssignment.find_by(
          scope_type: scope_type, scope_id: scope_id, function: @function.to_s
        )
        return assignment if assignment
      end
      nil
    end

    # Most-specific first: Page -> Template -> Account -> System.
    def scopes
      result = []
      result << ["Page", @page.id] if @page
      result << ["Template", @page.template_id] if @page&.template_id
      result << ["Account", @account.id] if @account
      result << ["System", nil]
      result
    end

    def config_for(model, options, fallback_model: nil)
      provider = model.ai_provider
      Llm::Config.new(
        provider_kind: provider.kind,
        provider_name: provider.name,
        api_model_id: model.api_model_id,
        base_url: provider.base_url,
        organization_id: provider.organization_id,
        request_timeout: provider.request_timeout || 120,
        capabilities: symbolize(model.capabilities),
        options: symbolize(options),
        api_key_resolver: -> { provider.api_key },
        fallback: fallback_model ? config_for(fallback_model, options) : nil
      )
    end

    def symbolize(hash)
      (hash || {}).each_with_object({}) { |(k, v), h| h[k.to_sym] = v }
    end
  end
end
