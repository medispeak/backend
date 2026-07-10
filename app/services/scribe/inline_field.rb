module Scribe
  # Duck-typed field for an ad-hoc (inline) form output — the same seam
  # SchemaBuilder consumes for FormField / NoteField. `title` is the RESULT key
  # (SchemaBuilder keys properties by #title); `friendly_name` is the human label.
  InlineField = Struct.new(
    :title, :friendly_name, :description, :field_type,
    :enum_options, :minimum, :maximum, keyword_init: true
  ) do
    TYPES = %w[string number boolean single_select multi_select].freeze
    SELECT_TYPES = %w[single_select multi_select].freeze

    def self.from_payload(hash)
      h = hash.to_h.with_indifferent_access
      new(
        title: h[:key], friendly_name: h[:label].presence || h[:key],
        description: h[:description], field_type: h[:type],
        enum_options: h[:enum], minimum: h[:minimum], maximum: h[:maximum]
      )
    end

    def self.build_all(fields)
      Array(fields).map { |f| from_payload(f) }
    end

    def self.validation_error(fields)
      return "fields must be a non-empty array" unless fields.is_a?(Array) && fields.any?

      seen = []
      fields.each do |f|
        h = f.to_h.with_indifferent_access
        key = h[:key]
        return "each field needs a key" if key.blank?
        return "duplicate field key: #{key}" if seen.include?(key)

        seen << key
        return "invalid field type: #{h[:type].inspect}" unless TYPES.include?(h[:type].to_s)

        if SELECT_TYPES.include?(h[:type].to_s) && Array(h[:enum]).empty?
          return "#{h[:type]} field #{key} requires enum options"
        end
      end
      nil
    end
  end
end
