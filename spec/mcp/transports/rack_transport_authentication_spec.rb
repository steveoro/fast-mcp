# frozen_string_literal: true

require 'rack'

RSpec.describe 'FastMcp::Transports::RackTransport with authentication' do
  let(:server) { FastMcp::Server.new(name: 'test-server', version: '1.0.0', logger: Logger.new(nil)) }
  let(:app) { ->(_env) { [200, { 'Content-Type' => 'text/plain' }, ['downstream']] } }
  let(:authenticator) { FastMcp::Authentication::TokenAuthenticator.new(token: 's3cret', principal: :owner) }
  let(:transport) do
    FastMcp::Transports::RackTransport.new(app, server, authenticator: authenticator, localhost_only: false)
  end

  # Reports whichever principal the transport put in the request context, so we can prove it
  # survives all the way into a tool call.
  let(:principal_tool) do
    Class.new(FastMcp::Tool) do
      tool_name 'whoami'
      description 'Reports the principal for this request'

      def call
        { principal: self.class.server.current_request_context&.dig(:principal).inspect }
      end
    end
  end

  before { server.register_tool(principal_tool) }

  def post_mcp(authorization: nil, body: nil)
    payload = body || { jsonrpc: '2.0', method: 'tools/call', params: { name: 'whoami', arguments: {} }, id: 1 }
    env = Rack::MockRequest.env_for(
      '/mcp/messages',
      method: 'POST',
      input: JSON.generate(payload),
      'CONTENT_TYPE' => 'application/json',
      'REMOTE_ADDR' => '127.0.0.1',
      # Satisfies the DNS-rebinding origin check, which runs before authentication.
      'HTTP_ORIGIN' => 'http://localhost'
    )
    env['HTTP_AUTHORIZATION'] = authorization if authorization

    transport.call(env)
  end

  describe 'without credentials' do
    it 'refuses with 401 and a JSON-RPC error' do
      status, headers, body = post_mcp

      expect(status).to eq(401)
      expect(headers['Content-Type']).to eq('application/json')
      expect(JSON.parse(body.join).dig('error', 'message')).to match(/Unauthorized/)
    end

    it 'does not reach the tool' do
      expect(server).not_to receive(:handle_request)

      post_mcp(authorization: 'Bearer wrong')
    end
  end

  # This endpoint answers over the SSE channel rather than in the HTTP body, so the reply is
  # observed where the transport broadcasts it.
  def reported_principal(**options)
    broadcast = nil
    allow(transport).to receive(:send_message) { |message| broadcast = message }

    post_mcp(**options)

    text = broadcast.dig(:result, :content, 0, :text)
    JSON.parse(text)['principal']
  end

  describe 'with valid credentials' do
    it 'admits the request and exposes the principal to the tool' do
      expect(post_mcp(authorization: 'Bearer s3cret').first).to eq(200)
      expect(reported_principal(authorization: 'Bearer s3cret')).to eq(':owner')
    end

    it 'clears the principal once the request is over' do
      post_mcp(authorization: 'Bearer s3cret')

      expect(server.current_request_context).to be_nil
    end
  end

  describe 'when no authenticator is configured' do
    let(:transport) { FastMcp::Transports::RackTransport.new(app, server, localhost_only: false) }

    it 'admits the request, and the context carries no principal' do
      expect(post_mcp.first).to eq(200)
      expect(reported_principal).to eq('nil')
    end
  end

  # A browser never attaches credentials to a preflight. If authentication ran first the
  # preflight would 401, the real request would never be sent, and an authenticated transport
  # would be unreachable from a browser.
  describe 'CORS preflight' do
    def preflight(path: '/mcp/sse', request_method: 'GET')
      env = Rack::MockRequest.env_for(
        path,
        method: 'OPTIONS',
        'REMOTE_ADDR' => '127.0.0.1',
        'HTTP_ORIGIN' => 'http://localhost',
        'HTTP_ACCESS_CONTROL_REQUEST_METHOD' => request_method,
        'HTTP_ACCESS_CONTROL_REQUEST_HEADERS' => 'authorization'
      )

      transport.call(env)
    end

    it 'is answered without credentials' do
      status, headers, = preflight

      expect(status).to eq(200)
      expect(headers['Access-Control-Allow-Origin']).to eq('*')
    end

    it 'advertises the methods and headers a real request needs' do
      _status, headers, = preflight(request_method: 'POST')

      expect(headers['Access-Control-Allow-Methods']).to include('GET', 'POST', 'OPTIONS')
      expect(headers['Access-Control-Allow-Headers']).to include('Authorization')
      expect(headers['Access-Control-Allow-Headers']).to include('Content-Type')
    end

    it 'is answered on the messages route too' do
      expect(preflight(path: '/mcp/messages').first).to eq(200)
    end

    # The whole point of answering the preflight: the credentialed request that follows works.
    it 'is followed by a successful authenticated request' do
      expect(preflight.first).to eq(200)
      expect(post_mcp(authorization: 'Bearer s3cret').first).to eq(200)
    end

    it 'still refuses a preflight from a disallowed origin' do
      env = Rack::MockRequest.env_for(
        '/mcp/sse',
        method: 'OPTIONS',
        'REMOTE_ADDR' => '127.0.0.1',
        'HTTP_ORIGIN' => 'http://evil.example.com'
      )

      expect(transport.call(env).first).to eq(403)
    end
  end

  describe 'requests outside the MCP path' do
    it 'are passed through untouched, with no authentication applied' do
      env = Rack::MockRequest.env_for('/somewhere-else', 'REMOTE_ADDR' => '127.0.0.1')

      status, _headers, body = transport.call(env)

      expect(status).to eq(200)
      expect(body.join).to eq('downstream')
    end
  end
end
