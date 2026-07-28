# Realtime WebRTC transcription and the never-implemented "combined"
# multimodal function were removed (record-then-process simplification).
# Delete their ModelAssignment rows so no config addresses a function the
# resolver no longer serves. Raw SQL: ModelAssignment now validates
# function inclusion against the shrunken FUNCTIONS list, and a data
# migration must not depend on model validations either way.
class RemoveRealtimeAndCombinedAssignments < ActiveRecord::Migration[8.0]
  def up
    execute "DELETE FROM model_assignments WHERE function IN ('realtime', 'combined')"
  end

  def down
    # Deleted configuration rows are not restorable; re-seed if ever needed.
  end
end
