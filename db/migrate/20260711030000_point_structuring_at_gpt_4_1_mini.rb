# Data migration: switch the System `structuring` model from gpt-4o-mini to
# gpt-4.1-mini. Benchmarked ~1.4s vs gpt-4o-mini ~1.5-3.3s and the gpt-5 series
# ~3.5-9s (reasoning overhead) for clinical form extraction — faster form-fill,
# newer than the 4o family. Idempotent and guarded: no-ops if the seeded
# provider/assignment aren't present (e.g. a fresh schema-load + seed install,
# where the seeds already use gpt-4.1-mini).
class PointStructuringAtGpt41Mini < ActiveRecord::Migration[8.0]
  def up
    assignment = ModelAssignment.find_by(scope_type: "System", scope_id: nil, function: "structuring")
    return unless assignment

    provider = assignment.ai_model&.ai_provider
    return unless provider

    model = AiModel.find_or_create_by!(ai_provider: provider, api_model_id: "gpt-4.1-mini") do |m|
      m.display_name = "GPT-4.1 mini"
      m.capabilities = {
        "can_structure" => true,
        "supports_json_schema" => true,
        "supports_function_calling" => true
      }
    end

    assignment.update!(ai_model: model)
  end

  def down
    # Reverting the model choice is a configuration decision, not a schema change.
  end
end
