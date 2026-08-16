require "administrate/field/base"

module Administrate
  module Field
    # Renders a jsonb object column as editable JSON text.
    #
    # Field::Text is the wrong tool for jsonb: its textarea renders the Hash
    # via #to_s (Ruby inspect — `{"a" => true}`), which is not valid JSON, and
    # what comes back is a String that Rails persists as a JSON *string*
    # scalar. This field always shows real JSON; the model side
    # (JsonObjectColumns) parses the submitted text back into a Hash.
    class JsonObject < Administrate::Field::Base
      def self.searchable?
        false
      end

      def self.html_class
        "json_object"
      end

      # Pretty JSON for the form/show; a String (invalid submission being
      # re-rendered) is shown verbatim so the admin can fix it.
      def to_s
        pretty? ? JSON.pretty_generate(data) : data.to_s
      end

      def compact
        data.is_a?(Hash) ? JSON.generate(data) : data.to_s
      end

      private

      def pretty?
        data.is_a?(Hash)
      end
    end
  end
end
