require "resolv"
require "ipaddr"

module Scribe
  # Where a customer webhook may point, and which address it may reach.
  #
  # Validating the URL at create time is not enough on its own: the HTTP client
  # resolves the host again minutes later, so a low-TTL record can pass
  # validation and then answer with an internal address (DNS rebinding).
  # Delivery therefore resolves ONCE through .pin and connects to that verified
  # address, leaving the hostname in place for TLS.
  module WebhookTarget
    class UnsafeTarget < StandardError; end

    # Loopback, RFC-1918 private, link-local (incl. the 169.254.169.254 cloud
    # metadata endpoint), unspecified, and the IPv6 equivalents.
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

    class << self
      def https_uri(value)
        uri = URI.parse(value)
        return nil unless uri.is_a?(URI::HTTPS) && uri.hostname.present?

        uri
      rescue URI::InvalidURIError
        nil
      end

      # Validation-time check. An unresolvable host is accepted here (it can
      # reach nothing internal) — .pin is what refuses it at delivery.
      def unsafe_host?(host)
        addresses_for(host).any? { |address| blocked?(address) }
      end

      # The single address delivery is allowed to connect to. Every answer must
      # be safe: a resolver that returns one public and one internal address is
      # refused outright rather than raced.
      def pin(uri)
        addresses = addresses_for(uri.hostname)
        raise UnsafeTarget, "#{uri.hostname} does not resolve" if addresses.empty?

        if addresses.any? { |address| blocked?(address) }
          raise UnsafeTarget, "#{uri.hostname} resolves to a private, loopback, or link-local address"
        end

        addresses.first
      end

      private

      # A literal IP is taken as-is; anything else goes through DNS.
      def addresses_for(host)
        IPAddr.new(host)
        [ host ]
      rescue IPAddr::InvalidAddressError
        resolve(host)
      end

      def resolve(host)
        Resolv.getaddresses(host)
      rescue StandardError
        []
      end

      def blocked?(address)
        BLOCKED_IP_RANGES.any? { |range| range.include?(IPAddr.new(address)) }
      rescue IPAddr::InvalidAddressError
        false
      end
    end
  end
end
