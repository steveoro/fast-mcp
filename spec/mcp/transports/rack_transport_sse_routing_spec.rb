# frozen_string_literal: true

# §1.3/§1.4 end to end on RackTransport: the endpoint event carries a server-issued sessionId,
# a client that POSTs to exactly that URL is served, replies and notifications go only to the
# session that asked, a disconnect drops its subscriptions, and idle sessions are reaped.

RSpec.describe FastMcp::Transports::RackTransport, 'SSE session routing (§1.3/§1.4)' do
  let(:logger) { Logger.new(nil) }
  let(:app) { ->(_env) { [200, {}, ['OK']] } }
  let(:server) { FastMcp::Server.new(name: 't', version: '0', logger: logger) }
  let(:transport_options) { {} }
  let(:transport) do
    described_class.new(app, server, logger: logger, localhost_only: false, **transport_options)
  end
  let(:counter_resource) do
    Class.new(FastMcp::Resource) do
      uri 'counter'
      resource_name 'Counter'
      description 'Synthetic counter'
      mime_type 'text/plain'
      def content = '0'
    end
  end

  before { server.register_resource(counter_resource) }
  after { transport.stop }

  # Opens an SSE stream through rack.hijack and returns [io, endpoint URL from the endpoint event].
  def open_sse(query = nil)
    io = StringIO.new
    env = Rack::MockRequest.env_for(['/mcp/sse', query].compact.join('?'), method: 'GET', 'REMOTE_ADDR' => '127.0.0.1', 'HTTP_HOST' => 'localhost')
    env['rack.hijack'] = -> {}
    env['rack.hijack_io'] = io
    transport.call(env)
    [io, io.string[/^event: endpoint\ndata: (.+)$/, 1]]
  end

  def post(url, payload)
    env = Rack::MockRequest.env_for(url, method: 'POST', input: JSON.generate(payload),
                                         'CONTENT_TYPE' => 'application/json', 'REMOTE_ADDR' => '127.0.0.1', 'HTTP_HOST' => 'localhost')
    transport.call(env)
  end

  def messages_on(io)
    io.string.scan(/^data: (\{.*\})$/).flatten.map { |line| JSON.parse(line) }
  end

  def session_id_from(url)
    Rack::Utils.parse_query(URI(url).query)['sessionId']
  end

  it 'puts a server-issued sessionId in the endpoint event, and a POST to that URL is served' do
    io, endpoint = open_sse

    expect(endpoint).to start_with('/mcp/messages?sessionId=')
    expect(transport.sse_clients).to have_key(session_id_from(endpoint))

    status, = post(endpoint, jsonrpc: '2.0', id: 1, method: 'ping')

    expect(status).to eq(200)
    expect(messages_on(io)).to include('jsonrpc' => '2.0', 'id' => 1, 'result' => {})
  end

  it 'keeps the GET query in the endpoint URL and ignores a client-chosen client_id' do
    _io, endpoint = open_sse('client_id=chosen&tenant=alpha')
    query = Rack::Utils.parse_query(URI(endpoint).query)

    expect(query['tenant']).to eq('alpha')
    expect(query['sessionId']).not_to eq('chosen')
    expect(transport.sse_clients).not_to have_key('chosen')
  end

  it 'delivers each reply only to the session that sent the request' do
    io_a, endpoint_a = open_sse
    io_b, = open_sse

    post(endpoint_a, jsonrpc: '2.0', id: 'from-a', method: 'ping')

    expect(messages_on(io_a).map { |m| m['id'] }).to include('from-a')
    expect(messages_on(io_b).map { |m| m['id'] }).not_to include('from-a')
  end

  it 'keys subscriptions by session, notifies only the subscriber and drops them on disconnect' do
    io_a, endpoint_a = open_sse
    io_b, endpoint_b = open_sse
    [endpoint_a, endpoint_b].each { |url| post(url, jsonrpc: '2.0', method: 'notifications/initialized') }

    post(endpoint_a, jsonrpc: '2.0', id: 2, method: 'resources/subscribe', params: { uri: 'counter' })
    server.notify_resource_updated('counter')

    updated = ->(io) { messages_on(io).count { |m| m['method'] == 'notifications/resources/updated' } }
    expect(updated.call(io_a)).to eq(1)
    expect(updated.call(io_b)).to eq(0)

    transport.send(:cleanup_sse_connection, session_id_from(endpoint_a), io_a)
    expect(server.instance_variable_get(:@resource_subscriptions)).to be_empty
  end

  context 'with a short sse_idle_timeout' do
    let(:transport_options) { { sse_idle_timeout: 60 } }

    it 'reaps a session with no POST activity, even though the server keeps pinging it' do
      io, endpoint = open_sse
      session_id = session_id_from(endpoint)
      later = Time.now + 120
      allow(Time).to receive(:now).and_return(later)

      _io_b, endpoint_b = open_sse # any GET or POST runs the reaper

      expect(transport.sse_clients).not_to have_key(session_id)
      expect(transport.sse_clients).to have_key(session_id_from(endpoint_b))
      expect(io).to be_closed
    end

    it 'keeps a session alive while it POSTs' do
      _io, endpoint = open_sse
      start = Time.now
      allow(Time).to receive(:now).and_return(start + 50)
      post(endpoint, jsonrpc: '2.0', id: 1, method: 'ping')
      allow(Time).to receive(:now).and_return(start + 100)

      post(endpoint, jsonrpc: '2.0', id: 2, method: 'ping')

      expect(transport.sse_clients).to have_key(session_id_from(endpoint))
    end
  end

  context 'without require_sse_session (client-chosen ids)' do
    let(:transport_options) { { require_sse_session: false, allow_sse_reconnect_takeover: true } }

    it 'does not let the old stream cleanup unregister the stream that took over its id' do
      old_io, = open_sse('client_id=shared')
      new_io, = open_sse('client_id=shared')

      transport.send(:cleanup_sse_connection, 'shared', old_io)

      expect(transport.sse_clients.dig('shared', :stream)).to equal(new_io)
    end
  end

  it 'caps the body it reads to echo an id for an unknown session' do
    limited = described_class.new(app, server, logger: logger, localhost_only: false, max_request_bytes: 64)
    status, _, body = limited.call(
      Rack::MockRequest.env_for('/mcp/messages?sessionId=ghost', method: 'POST',
                                                                 input: JSON.generate(jsonrpc: '2.0', id: 9, method: 'ping', pad: 'x' * 500),
                                                                 'REMOTE_ADDR' => '127.0.0.1', 'HTTP_HOST' => 'localhost')
    )

    expect(status).to eq(404)
    expect(JSON.parse(body.join)).not_to have_key('id')
  end
end
