# frozen_string_literal: true

# §1.4: legacy SSE session semantics.
# POST without a sessionId → 400; unknown sessionId → 404 echoing the JSON-RPC id;
# duplicate GET with a known connected id → 409, original stream untouched.

RSpec.describe FastMcp::Transports::RackTransport, 'SSE session semantics (§1.4)' do
  let(:app) { ->(_env) { [200, {}, ['OK']] } }
  let(:logger) { Logger.new(nil) }

  let(:server) do
    instance_double(
      FastMcp::Server,
      logger: logger,
      transport: nil,
      'transport=' => nil,
      contains_filters?: false,
      handle_request: nil,
      respond_to?: false,
      remove_subscriber: 0
    )
  end

  let(:transport) do
    described_class.new(app, server,
                        require_sse_session: true,
                        allow_sse_reconnect_takeover: false,
                        logger: logger,
                        localhost_only: false)
  end

  def post_messages_env(body, session_id: nil, path: '/mcp/messages')
    query = session_id ? "sessionId=#{session_id}" : ''
    input = StringIO.new(body)
    env = Rack::MockRequest.env_for("#{path}?#{query}",
                                    method: 'POST',
                                    input: input,
                                    'CONTENT_TYPE' => 'application/json',
                                    'REMOTE_ADDR' => '127.0.0.1',
                                    'HTTP_HOST' => '127.0.0.1')
    env
  end

  def get_sse_env(client_id: nil)
    url = '/mcp/sse'
    url += "?client_id=#{client_id}" if client_id
    Rack::MockRequest.env_for(url, method: 'GET',
                              'REMOTE_ADDR' => '127.0.0.1',
                              'HTTP_HOST' => '127.0.0.1')
  end

  # ── POST without sessionId → 400 ──────────────────────────────────────────

  describe 'POST /messages without sessionId → 400 (§1.4)' do
    it 'returns 400 with -32600 when sessionId param is absent' do
      env = post_messages_env('{"jsonrpc":"2.0","id":1,"method":"ping"}')
      status, _, body_parts = transport.call(env)
      expect(status).to eq(400)
      response = JSON.parse(body_parts.join)
      expect(response['error']['code']).to eq(-32_600)
      expect(response['error']['message']).to match(/sessionId/i)
    end
  end

  # ── POST with unknown sessionId → 404 echoing the JSON-RPC id ─────────────

  describe 'POST /messages with unknown sessionId → 404 (§1.4)' do
    it 'returns 404 with -32001 and echoes the request id when body is parseable' do
      body = JSON.generate(jsonrpc: '2.0', id: 42, method: 'ping')
      env = post_messages_env(body, session_id: 'ghost-session-id')
      status, _, body_parts = transport.call(env)
      expect(status).to eq(404)
      response = JSON.parse(body_parts.join)
      expect(response['error']['code']).to eq(-32_001)
      expect(response['id']).to eq(42)
    end

    it 'returns 404 with id null when the body is unparseable' do
      env = post_messages_env('not-json', session_id: 'ghost')
      status, _, body_parts = transport.call(env)
      expect(status).to eq(404)
      response = JSON.parse(body_parts.join)
      expect(response['error']['code']).to eq(-32_001)
      expect(response['id']).to be_nil
    end
  end

  # ── Duplicate GET /sse with a connected id → 409 ──────────────────────────

  describe 'duplicate GET /sse with a connected id → 409 (§1.4)' do
    let(:mock_stream) do
      s = instance_double('IO', closed?: false, close: nil, write: nil, flush: nil)
      allow(s).to receive(:respond_to?).with(:close).and_return(true)
      allow(s).to receive(:respond_to?).with(:flush).and_return(true)
      s
    end

    before do
      # Pre-register a client so the duplicate check fires
      transport.register_sse_client('existing-client', mock_stream)
    end

    it 'returns 409 for a second GET with the same client_id' do
      env = get_sse_env(client_id: 'existing-client')
      status, _, body_parts = transport.call(env)
      expect(status).to eq(409)
      response = JSON.parse(body_parts.join)
      expect(response['error']['code']).to eq(-32_000)
    end

    it 'does not close the original stream on a duplicate GET' do
      env = get_sse_env(client_id: 'existing-client')
      transport.call(env)
      expect(mock_stream).not_to have_received(:close)
    end

    it 'still has the original client registered after the 409' do
      env = get_sse_env(client_id: 'existing-client')
      transport.call(env)
      expect(transport.sse_clients).to have_key('existing-client')
    end
  end

  # ── allow_sse_reconnect_takeover: true ────────────────────────────────────

  describe 'with allow_sse_reconnect_takeover: true' do
    let(:transport) do
      described_class.new(app, server,
                          require_sse_session: true,
                          allow_sse_reconnect_takeover: true,
                          logger: logger,
                          localhost_only: false)
    end

    it 'is instantiated without raising' do
      expect(transport).to be_a(described_class)
    end
  end

  # ── require_sse_session: false bypasses checks ────────────────────────────

  describe 'with require_sse_session: false' do
    let(:transport) do
      described_class.new(app, server,
                          require_sse_session: false,
                          logger: logger,
                          localhost_only: false)
    end

    it 'passes the request to the server without checking for a sessionId' do
      expect(server).to receive(:handle_request)
      body = JSON.generate(jsonrpc: '2.0', id: 1, method: 'ping')
      env = post_messages_env(body) # no session_id
      transport.call(env)
    end
  end
end
