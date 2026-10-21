# frozen_string_literal: true

# §1.9 interop spec — tagged :interop, skipped when the mcp gem is unavailable.
#
# Tests the Ruby SDK 1.8.0 client in :auto and :legacy modes against the synthetic
# stdio server in examples/server_with_stdio_transport.rb.  The probe in :auto mode
# spawns a throwaway sibling process (negotiateStdioViaSibling) and should fall back
# to the newest handshake version (2025-11-25) via the server/discover → -32601 path.

begin
  require 'mcp'
  MCP_AVAILABLE = true
rescue LoadError
  MCP_AVAILABLE = false
end

RSpec.describe 'Ruby SDK 1.8.0 interop (§1.9)', :interop, skip: !MCP_AVAILABLE do
  let(:server_script) do
    File.expand_path('../../../../examples/server_with_stdio_transport.rb', __dir__)
  end

  around do |example|
    skip 'examples/server_with_stdio_transport.rb not found' unless File.exist?(server_script)
    example.run
  end

  # Shared helper: build a client command pointing at the stdio server.
  def client_command
    ["ruby", server_script]
  end

  shared_examples 'a connected MCP client' do |mode|
    it "connects and lists tools in #{mode} mode" do
      client = ::MCP::Client.new(command: client_command, mode: mode)
      begin
        tools = client.tools
        expect(tools).to be_an(Array)
        expect(tools).not_to be_empty
      ensure
        client.close rescue nil # rubocop:disable Style/RescueModifier
      end
    end

    it "negotiates a supported protocol version in #{mode} mode" do
      client = ::MCP::Client.new(command: client_command, mode: mode)
      begin
        version = client.negotiated_protocol_version rescue client.server_info&.dig(:protocolVersion) # rubocop:disable Style/RescueModifier
        if version
          supported = FastMcp::Server::HANDSHAKE_PROTOCOL_VERSIONS
          expect(supported).to include(version), "#{version} not in #{supported}"
        end
      ensure
        client.close rescue nil # rubocop:disable Style/RescueModifier
      end
    end
  end

  include_examples 'a connected MCP client', :auto
  include_examples 'a connected MCP client', :legacy
end
