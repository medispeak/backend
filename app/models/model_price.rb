class ModelPrice < ApplicationRecord
  include EffectiveDated

  validates :provider, presence: true
  validates :model, presence: true
end
