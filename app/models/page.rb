class Page < ApplicationRecord
  belongs_to :template
  has_many :form_fields, dependent: :destroy

  accepts_nested_attributes_for :form_fields, allow_destroy: true,
                                              reject_if: ->(attrs) { attrs["title"].blank? && attrs["friendly_name"].blank? }

  validates :name, presence: true
end
