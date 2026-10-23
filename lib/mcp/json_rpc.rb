# frozen_string_literal: true

module FastMcp
  # JSON-RPC 2.0 helpers shared by the server and the transports.
  #
  # Error replies follow the MCP Ruby SDK 1.8.1 rule (D-17): the `id` member is present only
  # when the request's id could be read and is valid (an Integer, or a String with a valid
  # encoding). It is omitted for parse errors, non-object bodies, a missing or null id and
  # invalid id types, because MCP allows only a string or an integer there.
  #
  # @example
  #   FastMcp::JsonRpc.error_response(-32_600, 'Invalid Request', nil)
  #   # => { jsonrpc: '2.0', error: { code: -32600, message: 'Invalid Request' } }
  module JsonRpc
    module_function

    # @param id [Object] the request id as read from the message, or nil
    # @return [Boolean] true for an Integer, or a String whose encoding is valid
    def valid_id?(id)
      id.is_a?(Integer) || (id.is_a?(String) && id.valid_encoding?)
    end

    # @param id [Object] the request id as read from the message, or nil
    # @return [Hash] `{ id: id }` for a valid id, `{}` otherwise
    def error_id_member(id)
      valid_id?(id) ? { id: id } : {}
    end

    # Builds a JSON-RPC error response.
    #
    # @param code [Integer] JSON-RPC error code
    # @param message [String] error message
    # @param id [Object, nil] the request id, echoed only when valid
    # @param data [Object, nil] optional `error.data`
    # @return [Hash] the response, ready for JSON.generate
    def error_response(code, message, id = nil, data: nil)
      error = { code: code, message: message }
      error[:data] = data unless data.nil?
      { jsonrpc: '2.0', error: error }.merge(error_id_member(id))
    end

    # A pre-encoded -32603 reply for when a response can't be encoded. It is built from ASCII
    # literals and a valid id only, so generating it can't fail again.
    #
    # @param id [Object, nil] the request id, echoed only when valid
    # @return [String] the encoded JSON-RPC error
    def internal_error_json(id = nil)
      safe_id = id.is_a?(String) ? id.dup.force_encoding(Encoding::UTF_8) : id
      JSON.generate(error_response(-32_603, 'Internal error', valid_id?(safe_id) ? safe_id : nil))
    end
  end
end
