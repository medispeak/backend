# Adds GPT-5.6 Luna (OpenAI direct AND via OpenRouter) and Gemini 3.6 Flash
# (OpenRouter) as selectable OCR + structuring models. Both handle image and
# PDF input and both clear OcrStage's 32k output cap.
#
# Selectable only: no assignment is changed, so nothing switches model until an
# operator picks one.
class ProvisionLunaAndGeminiModels < ActiveRecord::Migration[8.1]
  def up
    OpenrouterCatalog.provision!
    OpenaiCatalog.provision!
  end

  def down
    # Configuration rows; leave them in place.
  end
end
