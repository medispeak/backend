class ModelAssignment < ApplicationRecord
  SCOPES = %w[System Account Template Page].freeze
  FUNCTIONS = %w[asr structuring combined realtime].freeze

  belongs_to :ai_model
  belongs_to :fallback_ai_model, class_name: "AiModel", optional: true

  validates :scope_type, presence: true, inclusion: { in: SCOPES }
  validates :function, presence: true, inclusion: { in: FUNCTIONS }
  validates :scope_type, uniqueness: { scope: %i[scope_id function] }
  validate :scope_id_presence

  private

  def scope_id_presence
    if scope_type == "System" && scope_id.present?
      errors.add(:scope_id, "must be blank for System scope")
    elsif %w[Account Template Page].include?(scope_type) && scope_id.blank?
      errors.add(:scope_id, "is required for #{scope_type} scope")
    end
  end
end
