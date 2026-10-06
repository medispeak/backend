# Adds GPT-6 Luna (OpenAI direct) on high reasoning effort as a selectable OCR
# + structuring model. No assignment changes.
class ProvisionGpt6Luna < ActiveRecord::Migration[8.1]
  def up
    OpenaiCatalog.provision!
  end

  def down
    # Configuration rows; leave them in place.
  end
end
