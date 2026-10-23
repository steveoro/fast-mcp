# frozen_string_literal: true

# §1.9 interop spec — tagged :interop, skipped when the mcp gem is unavailable.
#
# Runs the official Ruby SDK client (mcp ~> 1.8) in :auto and :legacy modes against
# the synthetic stdio server in examples/server_with_stdio_transport.rb. In :auto mode
# the client probes server/discover first; fast-mcp answers -32601, so the client
# falls back to the initialize handshake and negotiates the newest handshake version.

begin
  require 'mcp'
  MCP_AVAILABLE = true
rescue LoadError
  MCP_AVAILABLE = false
end

RSpec.describe 'Ruby SDK interop (§1.9)', :interop, skip: !MCP_AVAILABLE do
  let(:server_script) do
    File.expand_path('../../../examples/server_with_stdio_transport.rb', __dir__)
  end

  # Starts the example server through the SDK's stdio transport and connects in `mode`.
  def connected_client(mode)
    transport = ::MCP::Client::Stdio.new(command: RbConfig.ruby, args: [server_script], read_timeout: 15)
    client = ::MCP::Client.new(transport: transport)
    client.connect(mode: mode, client_info: { name: 'fast-mcp-interop-spec', version: FastMcp::VERSION })
    client
  end

  it 'finds the example server' do
    expect(File).to exist(server_script)
  end

  %i[auto legacy].each do |mode|
    context "in #{mode} mode" do
      let!(:client) { connected_client(mode) }

      after { client.transport.close }

      it 'negotiates the newest handshake version' do
        expect(client.protocol_version).to eq(FastMcp::Server::HANDSHAKE_PROTOCOL_VERSIONS.first)
      end

      it 'lists the example tools' do
        expect(client.tools.map(&:name)).to include('add_user', 'delete_user')
      end
    end
  end
end
