# frozen_string_literal: true

require_relative '../json_rpc'
require_relative 'rack_transport'

module FastMcp
  module Transports
    # Extends RackTransport with static bearer-token authentication and reserved hooks for
    # future OAuth 2.1 / RFC 7662 token verification (§1.7, currently not implemented).
    #
    # OAuth hooks (not implemented):
    #   token_verifier:  a duck type that responds to #call(token) and returns a hash with
    #                    { subject:, scopes: [], expires_at:, resource: } or nil on failure.
    #   required_scopes: an Array<String> of scopes the token must carry.
    #
    # Both names are reserved: passing either raises ArgumentError, so a server configured with only
    # a token_verifier can't silently run unauthenticated. The design matches
    # the Ruby SDK 1.8.0 OAuth additions (iss+aud required, alg:none refused, no HMAC/RSA mixing).
    class AuthenticatedRackTransport < RackTransport
      def initialize(app, server, options = {})
        super

        @auth_token = options[:auth_token]
        @auth_header_name = options[:auth_header_name] || 'Authorization'
        @auth_exempt_paths = options[:auth_exempt_paths] || []
        @auth_enabled = !@auth_token.nil?
        # token_verifier / required_scopes: reserved, not implemented. Refuse them rather than
        # fail open (a server configured with only a verifier would otherwise be unauthenticated).
        @token_verifier  = options[:token_verifier]
        @required_scopes = Array(options[:required_scopes])
        if @token_verifier || @required_scopes.any?
          raise ArgumentError, 'token_verifier:/required_scopes: are reserved and not implemented in fast-mcp 1.8'
        end

        # A browser preflight has to be told it may send whichever header carries the credential.
        @cors_allowed_headers += [@auth_header_name]
      end

      def handle_mcp_request(request, env)
        # A browser never attaches credentials to a preflight, so requiring them here would make
        # this transport unreachable from a browser. RackTransport answers the OPTIONS request.
        if auth_enabled? && !request.options? && !exempt_from_auth?(request.path)
          auth_header = request.env["HTTP_#{@auth_header_name.upcase.gsub('-', '_')}"]
          token = auth_header&.gsub('Bearer ', '')

          return unauthorized_response(request) unless valid_token?(token)
        end

        super
      end

      private

      def auth_enabled?
        @auth_enabled
      end

      def exempt_from_auth?(path)
        @auth_exempt_paths.any? { |exempt_path| path.start_with?(exempt_path) }
      end

      def valid_token?(token)
        token == @auth_token
      end

      def unauthorized_response(request)
        @logger.error('Unauthorized request: Invalid or missing authentication token')
        body = JSON.generate(
          FastMcp::JsonRpc.error_response(-32_000, 'Unauthorized: Invalid or missing authentication token',
                                          extract_request_id(request))
        )

        [401, { 'Content-Type' => 'application/json' }, [body]]
      end

      def extract_request_id(request)
        return nil unless request.post?

        begin
          body = request.body.read
          request.body.rewind
          JSON.parse(body)['id']
        rescue StandardError
          nil
        end
      end
    end
  end
end
