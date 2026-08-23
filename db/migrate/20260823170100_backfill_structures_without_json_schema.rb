class BackfillStructuresWithoutJsonSchema < ActiveRecord::Migration[8.1]
  # Scribe::Orchestrator used to special-case provider_kind == :anthropic to let
  # those models structure without json_schema. That is a property of the model,
  # not of the caller, so it is now a declared capability — backfill the models
  # the special case used to cover so their behaviour is unchanged.
  def up
    execute(<<~SQL.squish)
      UPDATE ai_models
      SET capabilities = capabilities || '{"structures_without_json_schema": true}'::jsonb
      FROM ai_providers
      WHERE ai_models.ai_provider_id = ai_providers.id
        AND ai_providers.kind = 'anthropic'
        AND capabilities @> '{"can_structure": true}'::jsonb
    SQL
  end

  def down
    execute(<<~SQL.squish)
      UPDATE ai_models SET capabilities = capabilities - 'structures_without_json_schema'
    SQL
  end
end
