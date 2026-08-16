# Adds the OpenRouter ASR (dedicated STT endpoint) and structuring models as
# selectable rows on environments whose DB already exists (so db:seed does not
# re-run). Same idempotent pattern as ProvisionSarvamAndRealtime: creates only
# missing rows, never overwrites an operator's config, changes no defaults.
# The catalog itself lives in lib/openrouter_catalog.rb (shared with seeds).
class ProvisionOpenrouterModels < ActiveRecord::Migration[8.0]
  def up
    OpenrouterCatalog.provision!
  end

  def down
    # Configuration rows; leave them in place.
  end
end
