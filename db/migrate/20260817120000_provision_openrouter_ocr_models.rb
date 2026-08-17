# Adds the OpenRouter vision models as selectable OCR options and points the
# System-wide OCR default at the best of them.
#
# Until now no ModelAssignment existed for :ocr at any scope, so every document
# session fell through ConfigResolver to Llm::DefaultConfigProvider — the
# ENV-configured gpt-4o-mini on OpenAI direct. That is a general-purpose model
# picked as a default for structuring, it caps completions at 16,384 tokens
# (so OcrStage's page-sized budget gets clamped on a long report), and nothing
# about it was chosen for reading lab reports.
#
# Same idempotent pattern as ProvisionOpenrouterModels: the catalog lives in
# lib/openrouter_catalog.rb (shared with db/seeds.rb), rows are only created
# when missing, and the assignment step will not overwrite an operator who has
# already chosen an OCR model.
class ProvisionOpenrouterOcrModels < ActiveRecord::Migration[8.1]
  def up
    OpenrouterCatalog.provision!
    assignment = OpenrouterCatalog.assign_default_ocr!
    if assignment
      say "System OCR default: #{assignment.ai_model.api_model_id} " \
          "(fallback: #{assignment.fallback_ai_model&.api_model_id || 'none'})"
    else
      say "System OCR default left unchanged"
    end
  end

  def down
    # Configuration rows; leave them in place.
  end
end
