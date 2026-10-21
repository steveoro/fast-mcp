# frozen_string_literal: true

# §1.1b: fast-mcp answers server/discover with -32601 "Method not found" so that a TS/Ruby SDK
# client in `auto` mode sees the canonical "legacy server" signal and falls back to initialize.
# A 5xx or crash on this path would be a HARD failure with no fallback, so we pin the exact code.

RSpec.describe FastMcp::Server, 'server/discover probe contract (§1.1b)' do
  let(:server) { described_class.new(name: 't', version: '0', logger: Logger.new(nil)) }
  let(:transport) { instance_double('Transport', send_message: nil) }
  let(:captured) { [] }

  before do
    server.transport = transport
    allow(transport).to receive(:send_message) { |msg| captured << msg }
  end

  # Builds a well-formed modern envelope that a 2.3.1 TS client sends with server/discover.
  def discover_request(id:, protocol_version: '2026-07-28')
    JSON.generate(
      jsonrpc: '2.0',
      id: id,
      method: 'server/discover',
      params: {
        _meta: {
          'io.modelcontextprotocol/protocolVersion' => protocol_version,
          'io.modelcontextprotocol/clientCapabilities' => {}
        }
      }
    )
  end

  it 'returns -32601 and echoes the id for a well-formed 2026-07-28 envelope' do
    server.handle_request(discover_request(id: 7))
    expect(captured.size).to eq(1)
    msg = captured.first
    expect(msg[:jsonrpc]).to eq('2.0')
    expect(msg[:id]).to eq(7)
    expect(msg[:error][:code]).to eq(-32_601)
    expect(msg[:error][:message]).to include('server/discover')
  end

  it 'returns -32601 and echoes a string id' do
    server.handle_request(discover_request(id: 'probe-1'))
    msg = captured.first
    expect(msg[:id]).to eq('probe-1')
    expect(msg[:error][:code]).to eq(-32_601)
  end

  it 'returns -32601 for a malformed envelope (unknown extra fields present)' do
    req = JSON.generate(
      jsonrpc: '2.0',
      id: 99,
      method: 'server/discover',
      params: { _meta: { 'io.modelcontextprotocol/protocolVersion' => '2026-07-28',
                         'bad-key' => 'x' } }
    )
    server.handle_request(req)
    msg = captured.first
    expect(msg[:error][:code]).to eq(-32_601)
    expect(msg[:id]).to eq(99)
  end

  it 'returns -32601 for a future unsupported revision' do
    server.handle_request(discover_request(id: 3, protocol_version: '2099-01-01'))
    expect(captured.first[:error][:code]).to eq(-32_601)
  end

  it 'does NOT crash (no 5xx / exception) on any probe variant, so the client can fall back' do
    variants = [
      discover_request(id: 1),
      discover_request(id: 2, protocol_version: '2099-01-01'),
      JSON.generate(jsonrpc: '2.0', id: 3, method: 'server/discover', params: {}),
      JSON.generate(jsonrpc: '2.0', id: 4, method: 'server/discover')
    ]
    expect { variants.each { |v| server.handle_request(v) } }.not_to raise_error
    captured.each do |msg|
      expect(msg[:error][:code]).to eq(-32_601)
    end
  end

  it 'serves initialize normally after a failed server/discover on the same connection' do
    server.handle_request(discover_request(id: 10))
    captured.clear

    server.handle_request(
      JSON.generate(
        jsonrpc: '2.0', id: 11, method: 'initialize',
        params: { protocolVersion: '2025-11-25', capabilities: {}, clientInfo: {} }
      )
    )
    expect(captured.size).to eq(1)
    msg = captured.first
    expect(msg[:result]).to be_a(Hash)
    expect(msg[:result][:protocolVersion]).to eq('2025-11-25')
    expect(msg[:id]).to eq(11)
  end
end
