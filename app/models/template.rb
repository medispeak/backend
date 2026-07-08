class Template < ApplicationRecord
  # Optional: legacy templates predate ownership and keep account_id NULL
  # (admin-only-editable shared config). New user-created templates are owned by
  # the creator's account (plan 013, Path A).
  belongs_to :account, optional: true

  has_many :domains, dependent: :destroy
  has_many :pages, dependent: :destroy

  accepts_nested_attributes_for :pages, allow_destroy: true,
                                        reject_if: ->(attrs) { attrs["name"].blank? }

  validates :name, presence: true
  validates :description, presence: true

  scope :archived, -> { where(archived: true) }
  scope :active, -> { where(archived: false) }
end
