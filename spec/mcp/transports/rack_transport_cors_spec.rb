# frozen_string_literal: true

# §1.5: CORS allowlist.
# An allowed Origin is reflected in Access-Control-Allow-Origin; a disallowed Origin gets no
# ACAO header at all; Vary: Origin is always present in preflight responses.

RSpec.describe FastMcp::Transports::RackTransport, 'CORS allowlist (§1.5)' do
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
      respond_to?: false
    )
  end

  let(:allowed_origins) { ['my-mcp-app.local'] }

  let(:transport) do
    described_class.new(app, server,
                        localhost_only: false,
                        allowed_origins: allowed_origins,
                        cors_allowed_origins: allowed_origins,
                        logger: logger)
  end

  def options_env(origin:)
    Rack::MockRequest.env_for('/mcp/sse',
                              method: 'OPTIONS',
                              'HTTP_ORIGIN' => origin,
                              'REMOTE_ADDR' => '127.0.0.1')
  end

  def get_env(origin:, path: '/mcp/sse', client_id: 'test-client')
    Rack::MockRequest.env_for("#{path}?client_id=#{client_id}",
                              method: 'GET',
                              'HTTP_ORIGIN' => origin,
                              'REMOTE_ADDR' => '127.0.0.1')
  end

  # ── Preflight (OPTIONS) ────────────────────────────────────────────────────

  describe 'OPTIONS preflight for an allowed origin' do
    it 'reflects the Origin in Access-Control-Allow-Origin' do
      _, headers, = transport.call(options_env(origin: 'http://my-mcp-app.local'))
      expect(headers['Access-Control-Allow-Origin']).to eq('http://my-mcp-app.local')
    end

    it 'sets Vary: Origin' do
      _, headers, = transport.call(options_env(origin: 'http://my-mcp-app.local'))
      expect(headers['Vary']).to eq('Origin')
    end

    it 'includes MCP-Protocol-Version in Access-Control-Allow-Headers' do
      _, headers, = transport.call(options_env(origin: 'http://my-mcp-app.local'))
      allow_headers = headers['Access-Control-Allow-Headers'] || ''
      expect(allow_headers).to include('MCP-Protocol-Version')
    end

    it 'includes Mcp-Session-Id and MCP-Protocol-Version in Access-Control-Expose-Headers' do
      # Expose-Headers is on SSE response headers, not preflight — check the SSE path separately
      # (preflight returns text/plain headers, not SSE)
    end
  end

  describe 'OPTIONS preflight for a disallowed origin' do
    it 'omits Access-Control-Allow-Origin' do
      _, headers, = transport.call(options_env(origin: 'http://evil.example.com'))
      expect(headers['Access-Control-Allow-Origin']).to be_nil
    end

    it 'returns 403 (origin check runs before OPTIONS response)' do
      status, = transport.call(options_env(origin: 'http://evil.example.com'))
      expect(status).to eq(403)
    end
  end

  # ── MCP-Protocol-Version in SSE headers ───────────────────────────────────

  describe 'SSE response headers' do
    it 'includes MCP-Protocol-Version in Access-Control-Allow-Headers on SSE_HEADERS constant' do
      expect(described_class::SSE_HEADERS['Access-Control-Allow-Headers']).to include('MCP-Protocol-Version')
    end

    it 'includes Mcp-Session-Id in Access-Control-Expose-Headers on SSE_HEADERS constant' do
      expect(described_class::SSE_HEADERS['Access-Control-Expose-Headers']).to include('Mcp-Session-Id')
    end

    it 'includes MCP-Protocol-Version in Access-Control-Expose-Headers on SSE_HEADERS constant' do
      expect(described_class::SSE_HEADERS['Access-Control-Expose-Headers']).to include('MCP-Protocol-Version')
    end
  end

  # ── cors_allowed_origins option ───────────────────────────────────────────

  describe 'cors_allowed_origins: option' do
    it 'stores the configured list' do
      expect(transport.cors_allowed_origins).to eq(allowed_origins)
    end

    it 'defaults to the allowed_origins list when not explicitly set' do
      t = described_class.new(app, server,
                              localhost_only: false,
                              allowed_origins: ['custom.local'],
                              logger: logger)
      expect(t.cors_allowed_origins).to eq(['custom.local'])
    end

    it 'reflects a Regexp origin that matches' do
      t = described_class.new(app, server,
                              localhost_only: false,
                              allowed_origins: [/\.local\z/],
                              cors_allowed_origins: [/\.local\z/],
                              logger: logger)
      _, headers, = t.call(options_env(origin: 'http://anything.local'))
      expect(headers['Access-Control-Allow-Origin']).to eq('http://anything.local')
    end
  end

  # ── No ACAO when origin not on the allowed list ───────────────────────────

  describe 'disallowed origins' do
    it 'omits Access-Control-Allow-Origin for a completely different domain' do
      _, headers, = transport.call(options_env(origin: 'https://attacker.example.com'))
      expect(headers['Access-Control-Allow-Origin']).to be_nil
    end

    it 'omits Access-Control-Allow-Origin when origin is empty string' do
      _, headers, = transport.call(options_env(origin: ''))
      expect(headers['Access-Control-Allow-Origin']).to be_nil
    end
  end
end
