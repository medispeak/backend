require "resolv"
require "ipaddr"

class ScribeSession < ApplicationRecord
  # Ranges a webhook must never target: loopback, RFC-1918 private, link-local
  # (incl. 169.254.169.254 cloud metadata), unspecified, and IPv6 equivalents.
  BLOCKED_IP_RANGES = [
    IPAddr.new("127.0.0.0/8"),
    IPAddr.new("10.0.0.0/8"),
    IPAddr.new("172.16.0.0/12"),
    IPAddr.new("192.168.0.0/16"),
    IPAddr.new("169.254.0.0/16"),
    IPAddr.new("0.0.0.0/8"),
    IPAddr.new("::1"),
    IPAddr.new("fc00::/7"),
    IPAddr.new("fe80::/10")
  ].freeze

  belongs_to :account
  belongs_to :api_token, optional: true
  belongs_to :user, optional: true

  has_many :scribe_outputs, dependent: :destroy
  has_one :transcript, dependent: :destroy

  has_many_attached :audio_files

  # Audio upload allowlist + ceiling. The API controllers reject bad uploads
  # before attaching (with a surface-appropriate error); these attachment
  # validations are defense-in-depth for any other write path. Spoofing
  # protection is off, so this checks the declared content-type — a first-line
  # guard against a huge or non-audio payload reaching storage/ASR (plan 014).
  ALLOWED_AUDIO_TYPES = %w[
    audio/mpeg audio/mp4 audio/wav audio/x-wav audio/webm audio/ogg audio/m4a audio/aac
  ].freeze
  MAX_AUDIO_BYTES = 25.megabytes

  validates :audio_files,
            content_type: ALLOWED_AUDIO_TYPES,
            size: { less_than_or_equal_to: MAX_AUDIO_BYTES }

  enum :status, {
    created: "created",
    uploading: "uploading",
    processing: "processing",
    completed: "completed",
    partial: "partial",
    failed: "failed",
    expired: "expired"
  }

  # mode default is "consultation" (set at the column level). validate: false
  # keeps unknown/legacy modes from raising on read.
  enum :mode, { dictation: "dictation", consultation: "consultation" }, validate: false

  validates :status, presence: true
  validate :callback_url_is_safe

  def expired?
    expires_at.present? && expires_at < Time.current
  end

  private

  def callback_url_is_safe
    return if callback_url.blank?

    uri = parse_https_uri(callback_url)
    unless uri
      errors.add(:callback_url, "must be a valid https URL")
      return
    end

    if unsafe_host?(uri.hostname)
      errors.add(:callback_url, "must not point to a private, loopback, or link-local address")
    end
  end

  def parse_https_uri(value)
    uri = URI.parse(value)
    return nil unless uri.is_a?(URI::HTTPS) && uri.hostname.present?

    uri
  rescue URI::InvalidURIError
    nil
  end

  # A literal IP is checked directly; a hostname is resolved via DNS. An
  # unresolvable host resolves to [] and is treated as safe (it can reach
  # nothing internal).
  def unsafe_host?(host)
    ip_candidates(host).any? { |ip| blocked_ip?(ip) }
  end

  def ip_candidates(host)
    IPAddr.new(host) # raises unless host is already a literal IP
    [ host ]
  rescue IPAddr::InvalidAddressError
    resolve_addresses(host)
  end

  def resolve_addresses(host)
    Resolv.getaddresses(host)
  rescue StandardError
    []
  end

  def blocked_ip?(address)
    ip = IPAddr.new(address)
    BLOCKED_IP_RANGES.any? { |range| range.include?(ip) }
  rescue IPAddr::InvalidAddressError
    false
  end
end
