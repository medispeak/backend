module Scribe
  # Builds a ScribeSession and its ScribeOutput rows from a declared `outputs`
  # array.
  #
  # Extracted from Api::V2::ScribeSessionsController#create so the web
  # playground creates sessions through exactly the same validation and
  # construction path as the public API. A second construction site would drift
  # from the API the playground exists to demonstrate — and the validation it
  # would drift from is the tenancy check on `page_id`, which is the one that
  # matters.
  #
  # HTTP concerns stay in the controller: this returns a Result carrying either
  # the saved session or an {code:, message:} pair the caller renders however
  # its transport demands.
  class SessionBuilder
    OUTPUT_TYPES = %w[transcript form note].freeze
    # What a caller may declare. Omitted (or anything else) starts "pending" and
    # is fixed by the first upload the server stores.
    CLIENT_MODALITIES = %w[audio document].freeze

    Result = Struct.new(:session, :error, keyword_init: true) do
      def success?
        error.nil?
      end
    end

    def initialize(account:, outputs:, user: nil, api_token: nil, mode: nil,
                   modality: nil, language_hint: nil, callback_url: nil,
                   idempotency_key: nil)
      @account = account
      @outputs = Array(outputs).map { |output| output.to_h.with_indifferent_access }
      @user = user
      @api_token = api_token
      @mode = mode
      @modality = modality
      @language_hint = language_hint
      @callback_url = callback_url
      @idempotency_key = idempotency_key
    end

    def call
      message = validate_outputs
      return failure(message) if message

      session = build_session
      return failure(session.errors.full_messages.to_sentence) unless session.valid?

      session.save!
      build_outputs(session)

      Result.new(session: session)
    end

    private

    attr_reader :account, :outputs, :user, :api_token, :mode, :modality,
                :language_hint, :callback_url, :idempotency_key

    def failure(message)
      Result.new(error: { code: "validation_error", message: message })
    end

    def build_session
      ScribeSession.new(
        account: account,
        api_token: api_token,
        user: user,
        status: "created",
        # "pending" is server-managed; a client asking for it explicitly is
        # asking for nothing, so it means the same as omitting it.
        modality: CLIENT_MODALITIES.include?(modality.to_s) ? modality.to_s : "pending",
        language: language_hint,
        mode: mode.presence || "consultation",
        callback_url: callback_url,
        idempotency_key: idempotency_key,
        expires_at: 24.hours.from_now
      )
    end

    def build_outputs(session)
      outputs.each do |output|
        session.scribe_outputs.create!(
          status: "pending",
          output_type: output[:type],
          page_id: output[:page_id],
          template_ref: output[:template_ref],
          context: output[:context].presence || {},
          inline_fields: output[:fields].present? ? output[:fields].map { |f| f.to_h } : nil
        )
      end
    end

    # Returns an error message string, or nil when all outputs are valid.
    def validate_outputs
      return "outputs must be a non-empty array" if outputs.blank?

      outputs.each do |output|
        type = output[:type]

        unless OUTPUT_TYPES.include?(type)
          return "Invalid output type: #{type.inspect}"
        end

        next unless type == "form"

        # A form output carries EXACTLY one schema source: a persisted page_id
        # OR an inline `fields` array. Neither/both is a 422.
        page_id = output[:page_id]
        fields = output[:fields]
        has_page = page_id.present?
        has_fields = fields.present?
        return "form output needs exactly one of page_id or fields" if has_page == has_fields

        if has_page
          # Scope to pages the CALLER may use: its own account's templates or
          # legacy shared templates (account_id NULL, plan 013). Without this
          # scope a tenant could name another account's page_id and have the
          # pipeline read their form schema, prompt, and model assignment.
          # Same message for foreign vs absent pages so it isn't an existence
          # oracle.
          usable = Page.joins(:template)
                       .where(id: page_id)
                       .where(templates: { account_id: [ nil, account&.id ] })
                       .exists?
          unless usable
            return "page_id #{page_id.inspect} does not reference an existing page"
          end
        else
          err = Scribe::InlineField.validation_error(fields.map { |f| f.to_h })
          return err if err
        end
      end

      nil
    end
  end
end
