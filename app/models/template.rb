class Template < ApplicationRecord
  has_many :domains, dependent: :destroy
  has_many :pages, dependent: :destroy

  accepts_nested_attributes_for :pages, allow_destroy: true,
                                        reject_if: ->(attrs) { attrs["name"].blank? }

  validates :name, presence: true
  validates :description, presence: true

  scope :archived, -> { where(archived: true) }
  scope :active, -> { where(archived: false) }
end
