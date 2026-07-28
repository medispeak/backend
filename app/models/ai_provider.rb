class AiProvider < ApplicationRecord
  # gemini has no adapter; Gemini models are reachable through their
  # OpenAI-compatible endpoint as an openai_compatible provider row.
  KINDS = %w[openai_compatible anthropic sarvam].freeze

  # API key encrypted at rest (Active Record Encryption).
  encrypts :api_key

  has_many :ai_models, dependent: :destroy

  validates :name, presence: true
  validates :kind, presence: true, inclusion: { in: KINDS }

  scope :active, -> { where(active: true) }
end
