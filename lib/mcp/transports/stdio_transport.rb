# frozen_string_literal: true

require_relative '../json_rpc'
require_relative 'base_transport'

module FastMcp
  module Transports
    # STDIO transport for MCP.
    # Reads JSON-RPC messages from +input+ (default $stdin) line by line and writes responses to
    # +output+ (default $stdout). The +input:+ and +output:+ options let callers redirect IO so
    # that incidental Rails/gem log lines never corrupt the JSON stream (§1.2, §1.9, PR-2 §2.13).
    #
    # Line-length cap: lines longer than +max_request_bytes+ bytes are discarded and answered with
    # a -32600 error. The next valid line is still processed.
    #
    # Frames (§1.14.4, MCP Ruby SDK 1.8.1 #623/#625) are stripped as bytes, so a bad byte can't
    # raise under any locale. A frame that isn't valid UTF-8 gets -32700; any other failure gets
    # -32603 without the exception text (unless the server's +expose_internal_errors+ is on); and a
    # reply that can't be encoded is logged and replaced by a pre-built -32603.
    class StdioTransport < BaseTransport
      def initialize(server, logger: nil, input: nil, output: nil, max_request_bytes: nil)
        super(server, logger: logger)
        @input  = input   # nil → use $stdin dynamically at read time
        @output = output  # nil → use $stdout dynamically at write time
        @max_request_bytes = max_request_bytes
        @running = false
      end

      # Start the transport
      def start
        @logger.info('Starting STDIO transport')
        @running = true

        while @running
          line = read_line
          next if line == :retry  # over-limit line was already handled; try the next one
          break if line.nil?      # EOF

          handle_frame(line)
        end
      end

      # Stop the transport
      def stop
        @logger.info('Stopping STDIO transport')
        @running = false
      end

      # Send a message to the client
      def send_message(message)
        json_message = encode_message(message)
        out = @output || $stdout
        out.puts(json_message)
        out.flush
      end

      private

      # Processes one raw input line as a JSON-RPC frame.
      def handle_frame(line)
        frame = line.b.strip.force_encoding(Encoding::UTF_8)
        return send_error(-32_700, 'Parse error') unless frame.valid_encoding?

        process_message(frame)
      rescue StandardError => e
        @logger.error("Error processing message: #{e.class}: #{e.message}")
        @logger.error(e.backtrace.join("\n")) if e.backtrace
        expose = server.respond_to?(:expose_internal_errors?) && server.expose_internal_errors?
        send_error(-32_603, expose ? "Internal error: #{e.message}" : 'Internal error')
      end

      # Encodes an outbound message; a message that can't be encoded (e.g. invalid UTF-8 in a
      # tool result) becomes a -32603 reply carrying the request id when it is known.
      def encode_message(message)
        return message if message.is_a?(String)

        JSON.generate(message)
      rescue JSON::GeneratorError, EncodingError => e
        @logger.error("Could not encode the reply: #{e.class}: #{e.message}")
        JsonRpc.internal_error_json(message.is_a?(Hash) ? (message[:id] || message['id']) : nil)
      end

      # Reads one line from input, enforcing the max_request_bytes limit when set.
      # Returns :retry after discarding an over-limit line (so the loop can continue).
      # Returns nil on EOF.
      def read_line
        inp   = @input || $stdin
        limit = @max_request_bytes
        return inp.gets if limit.nil?

        line = inp.gets("\n", limit + 1)
        return nil if line.nil? # EOF

        if line.bytesize > limit
          # Drain the rest of this line so the next read starts clean.
          inp.gets unless line.end_with?("\n")
          @logger.warn("Received over-limit stdio line (#{line.bytesize} bytes), discarding")
          send_error(-32_600, "Request too large (limit #{limit} bytes)", nil)
          return :retry
        end

        line
      end

      # Send a JSON-RPC error response; the id member follows D-17 (FastMcp::JsonRpc).
      def send_error(code, message, id = nil)
        send_message(JsonRpc.error_response(code, message, id))
      end
    end
  end
end
