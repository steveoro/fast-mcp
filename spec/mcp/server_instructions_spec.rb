# frozen_string_literal: true

# §1.13: Server.new(instructions:) — sent in the initialize result when present.

RSpec.describe FastMcp::Server, 'instructions (§1.13)' do
  let(:logger) { Logger.new(nil) }
  let(:captured) { [] }
  let(:transport) { instance_double('Transport', send_message: nil) }
  let(:initialize_request) do
    { jsonrpc: '2.0', id: 1, method: 'initialize',
      params: { protocolVersion: '2025-11-25', capabilities: {}, clientInfo: { name: 'c', version: '0' } } }.to_json
  end

  def build_server(instructions)
    described_class.new(name: 't', version: '0', logger: logger, instructions: instructions).tap do |server|
      server.transport = transport
      allow(transport).to receive(:send_message) { |msg| captured << msg }
    end
  end

  def initialize_result(server, request: nil)
    if request
      server.with_request_context(transport: transport, request: request) { server.handle_request(initialize_request) }
    else
      server.handle_request(initialize_request)
    end
    captured.last.fetch(:result)
  end

  it 'sends a String in the initialize result' do
    server = build_server('Use search before deciding.')

    expect(initialize_result(server)[:instructions]).to eq('Use search before deciding.')
    expect(server.instructions).to eq('Use search before deciding.')
  end

  it 'strips the text' do
    expect(initialize_result(build_server("  Persist lessons.\n"))[:instructions]).to eq('Persist lessons.')
  end

  it 'passes the Rack request to a callable' do
    seen = []
    request = Rack::Request.new(Rack::MockRequest.env_for('/mcp/readonly'))
    server = build_server(->(req) { seen << req && "profile #{req.path}" })

    expect(initialize_result(server, request: request)[:instructions]).to eq('profile /mcp/readonly')
    expect(seen).to eq([request])
  end

  it 'passes nil to a callable on stdio (no request)' do
    seen = []
    server = build_server(->(req) { (seen << req) && 'stdio text' })

    expect(initialize_result(server)[:instructions]).to eq('stdio text')
    expect(seen).to eq([nil])
  end

  [nil, '', '   ', 42].each do |value|
    it "omits the key for #{value.inspect}" do
      expect(initialize_result(build_server(value))).not_to have_key(:instructions)
    end
  end

  it 'omits the key when the callable returns nil or blank' do
    expect(initialize_result(build_server(->(_req) {}))).not_to have_key(:instructions)
    expect(initialize_result(build_server(->(_req) { ' ' }))).not_to have_key(:instructions)
  end

  it 'logs a failing callable, omits the key and still completes the handshake' do
    allow(logger).to receive(:error)
    server = build_server(->(_req) { raise ArgumentError, 'boom' })

    result = initialize_result(server)

    expect(result).to include(:protocolVersion, :serverInfo)
    expect(result).not_to have_key(:instructions)
    expect(logger).to have_received(:error).with(/instructions callable failed: ArgumentError: boom/)
  end

  it 'applies no length cap' do
    text = 'x' * 10_000

    expect(initialize_result(build_server(text))[:instructions].length).to eq(10_000)
  end
end
