# frozen_string_literal: true

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

          begin
            process_message(line.strip)
          rescue StandardError => e
            @logger.error("Error processing message: #{e.message}")
            @logger.error(e.backtrace.join("\n"))
            send_error(-32_000, "Internal error: #{e.message}")
          end
        end
      end

      # Stop the transport
      def stop
        @logger.info('Stopping STDIO transport')
        @running = false
      end

      # Send a message to the client
      def send_message(message)
        json_message = message.is_a?(String) ? message : JSON.generate(message)
        out = @output || $stdout
        out.puts(json_message)
        out.flush
      end

      private

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

      # Send a JSON-RPC error response
      def send_error(code, message, id = nil)
        response = {
          jsonrpc: '2.0',
          error: {
            code: code,
            message: message
          },
          id: id
        }
        send_message(response)
      end
    end
  end
end
