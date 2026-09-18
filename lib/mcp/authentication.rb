# frozen_string_literal: true

require 'digest'
require 'ipaddr'

module FastMcp
  # Pluggable request authentication for HTTP transports.
  #
  # An *authenticator* is anything responding to `#call(request)`, where +request+ is a
  # Rack::Request. It returns either:
  #
  # - a **principal** — any truthy object — when the request is accepted. The transport places it
  #   in the server's per-request context, so a tool can read it with
  #   `self.class.server.current_request_context[:principal]`.
  # - +nil+ or +false+ when the request is refused, which the transport turns into a 401.
  #
  # The principal is deliberately opaque. A single-owner server can return a constant; an
  # application with real users can return a User record looked up from a database-backed
  # credential. Both plug into the same hook.
  #
  # Two implementations ship with the gem, and +Chain+ composes them:
  #
  #   FastMcp::Authentication::Chain.new(
  #     FastMcp::Authentication::IpAllowlist.new(%w[10.0.0.0/8 127.0.0.1]),
  #     FastMcp::Authentication::TokenAuthenticator.new(token: ENV.fetch('MCP_TOKEN'))
  #   )
  module Authentication
    # Rack env key holding the principal resolved for the current request.
    ENV_KEY = 'fast_mcp.principal'

    # Accepts a request carrying the expected shared bearer token.
    #
    # Suitable when one secret guards the whole server. For per-user credentials, write an
    # authenticator that looks the presented token up and returns the user it belongs to.
    class TokenAuthenticator
      BEARER = /\ABearer\s+/i

      # @param token [String] the expected secret; must not be blank
      # @param header [String] header to read the token from
      # @param principal [Object] value returned when the token matches
      # @raise [ArgumentError] when the token is blank
      def initialize(token:, header: 'Authorization', principal: :token)
        raise ArgumentError, 'token must not be blank' if token.nil? || token.to_s.strip.empty?

        @token = token.to_s
        @env_key = "HTTP_#{header.upcase.tr('-', '_')}"
        @principal = principal
      end

      # @param request [Rack::Request]
      # @return [Object, nil] the principal, or nil when the token is missing or wrong
      def call(request)
        presented = presented_token(request)
        return nil if presented.nil?
        return nil unless tokens_match?(presented, @token)

        @principal
      end

      private

      def presented_token(request)
        header = request.get_header(@env_key).to_s
        return nil unless header.match?(BEARER)

        value = header.sub(BEARER, '').strip
        value.empty? ? nil : value
      end

      # Constant-time comparison, so a wrong token cannot be discovered a byte at a time.
      # Both sides are digested first, which also keeps the comparison independent of length.
      def tokens_match?(presented, expected)
        left = Digest::SHA256.digest(presented)
        right = Digest::SHA256.digest(expected)

        result = 0
        left.bytes.each_with_index { |byte, index| result |= byte ^ right.getbyte(index) }
        result.zero?
      end
    end

    # Accepts a request whose client address falls inside one of the given ranges.
    #
    # The Rack transport reuses this class for its +allowed_ips+ option. It is
    # also useful as the first link of a Chain, or alone on a trusted network.
    class IpAllowlist
      # @param ranges [String, Array<String>] addresses or CIDR ranges; a single String may hold
      #   a comma-separated list
      # @param principal [Object] value returned when the address matches
      # @raise [ArgumentError] when no usable range is given
      def initialize(ranges, principal: true)
        @ranges = parse(ranges)
        raise ArgumentError, 'at least one valid range is required' if @ranges.empty?

        @principal = principal
      end

      # @param request [Rack::Request]
      # @return [Object, nil] the principal, or nil when the address is outside every range
      def call(request)
        address = normalize(request.ip)
        return nil if address.nil?

        @ranges.any? { |range| range.include?(address) } ? @principal : nil
      end

      private

      def parse(ranges)
        entries = case ranges
                  when nil then []
                  when Array then ranges
                  else ranges.to_s.split(',')
                  end

        entries.map { |entry| entry.to_s.strip }.reject(&:empty?).filter_map do |entry|
          IPAddr.new(entry)
        rescue IPAddr::Error
          nil
        end
      end

      # IPv4-mapped IPv6 addresses (::ffff:127.0.0.1) are compared as IPv4, so they match an
      # IPv4 range as a caller would expect.
      def normalize(address)
        parsed = IPAddr.new(address.to_s)
        parsed.ipv4_mapped? ? parsed.native : parsed
      rescue IPAddr::Error
        nil
      end
    end

    # Runs several authenticators in order, refusing as soon as one refuses.
    class Chain
      # @param authenticators [Array<#call>]
      # @raise [ArgumentError] when given nothing to run
      def initialize(*authenticators)
        @authenticators = authenticators.flatten.compact
        raise ArgumentError, 'at least one authenticator is required' if @authenticators.empty?
      end

      # @param request [Rack::Request]
      # @return [Object, nil] the most specific principal produced by the chain — links returning
      #   plain +true+ only vouch for the request without naming anyone — or nil if any refused
      def call(request)
        principal = true

        @authenticators.each do |authenticator|
          result = authenticator.call(request)
          return nil unless result

          principal = result unless result == true
        end

        principal
      end
    end
  end
end
