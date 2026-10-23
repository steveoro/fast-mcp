# frozen_string_literal: true

# §1.2: request body size limit. A request that exceeds max_request_bytes gets HTTP 413 with a
# JSON-RPC -32600 error. The guard checks Content-Length first (fast path) and then the actual
# body size (for chunked/streaming uploads with no Content-Length header).

RSpec.describe FastMcp::Transports::RackTransport, 'body size limit (§1.2)' do
  let(:app) { ->(_env) { [200, {}, ['OK']] } }
  let(:logger) { Logger.new(nil) }
  let(:limit) { 20 }

  let(:server) do
    instance_double(
      FastMcp::Server,
      logger: logger,
      transport: nil,
      'transport=' => nil,
      contains_filters?: false,
      handle_request: nil,
      respond_to?: false
    )
  end

  let(:transport) do
    described_class.new(app, server, max_request_bytes: limit, logger: logger,
                        localhost_only: false, allowed_origins: [],
                        require_sse_session: false)
  end

  def post_env(body, content_length: nil, path: '/mcp/messages', query: '')
    input = StringIO.new(body)
    env = Rack::MockRequest.env_for("#{path}?#{query}",
                                    method: 'POST',
                                    input: input,
                                    'CONTENT_TYPE' => 'application/json')
    env['CONTENT_LENGTH'] = content_length.to_s if content_length
    env['REMOTE_ADDR'] = '127.0.0.1'
    env
  end

  context 'when Content-Length exceeds the limit' do
    it 'returns 413 without reading the body' do
      oversized = '{"x":"' + 'y' * 100 + '"}'
      env = post_env(oversized, content_length: oversized.bytesize)
      status, headers, body_parts = transport.call(env)
      expect(status).to eq(413)
      response = JSON.parse(body_parts.join)
      expect(response['error']['code']).to eq(-32_600)
    end
  end

  context 'when Content-Length is absent (chunked-style) but the actual body is too large' do
    it 'returns 413 after reading the body' do
      oversized = '{"x":"' + 'z' * 100 + '"}'
      env = post_env(oversized) # no content_length
      status, _, body_parts = transport.call(env)
      expect(status).to eq(413)
      response = JSON.parse(body_parts.join)
      expect(response['error']['code']).to eq(-32_600)
    end
  end

  context 'when the body is within the limit' do
    it 'passes the body to the server and returns 200' do
      small = '{"jsonrpc":"2.0"}'
      expect(server).to receive(:handle_request).with(small, anything)
      env = post_env(small, content_length: small.bytesize)
      status, = transport.call(env)
      expect(status).to eq(200)
    end
  end

  context 'when max_request_bytes is nil (unlimited)' do
    let(:transport) do
      described_class.new(app, server, max_request_bytes: nil, logger: logger,
                          localhost_only: false, allowed_origins: [],
                          require_sse_session: false)
    end

    it 'passes large bodies through without error' do
      large = '{"x":"' + 'a' * 10_000 + '"}'
      expect(server).to receive(:handle_request).with(large, anything)
      env = post_env(large)
      status, = transport.call(env)
      expect(status).to eq(200)
    end
  end

  context 'with the default limit (4 MiB)' do
    let(:transport) do
      described_class.new(app, server, logger: logger, localhost_only: false, allowed_origins: [])
    end

    it 'has DEFAULT_MAX_REQUEST_BYTES set to 4 MiB' do
      expect(described_class::DEFAULT_MAX_REQUEST_BYTES).to eq(4 * 1024 * 1024)
    end

    it 'stores the default' do
      expect(transport.max_request_bytes).to eq(4 * 1024 * 1024)
    end
  end
end
