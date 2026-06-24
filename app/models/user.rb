class User < ApplicationRecord
  # Include default devise modules. Others available are:
  # :confirmable, :lockable, :timeoutable, :trackable and :omniauthable
  devise :database_authenticatable, :registerable,
         :recoverable, :rememberable, :validatable

  belongs_to :account, optional: true

  has_many :api_tokens, dependent: :destroy
  has_many :transcriptions, dependent: :destroy
  has_many :webapps, dependent: :destroy

  # Every user belongs to a billable account; create one on signup if absent.
  before_create :ensure_account

  private

  def ensure_account
    self.account ||= Account.create!(name: email.presence || "New Account")
  end
end
