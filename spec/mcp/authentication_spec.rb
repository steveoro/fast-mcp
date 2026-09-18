# frozen_string_literal: true

RSpec.describe FastMcp::Authentication do
  def request_for(authorization: nil, ip: '127.0.0.1')
    env = Rack::MockRequest.env_for('/mcp', 'REMOTE_ADDR' => ip)
    env['HTTP_AUTHORIZATION'] = authorization if authorization
    Rack::Request.new(env)
  end

  describe described_class::TokenAuthenticator do
    subject(:authenticator) { described_class.new(token: 's3cret') }

    it 'accepts the expected bearer token' do
      expect(authenticator.call(request_for(authorization: 'Bearer s3cret'))).to eq(:token)
    end

    it 'is case insensitive about the scheme and tolerates padding' do
      expect(authenticator.call(request_for(authorization: 'bearer   s3cret  '))).to eq(:token)
    end

    it 'refuses a wrong, missing, empty or differently-schemed token' do
      expect(authenticator.call(request_for(authorization: 'Bearer wrong'))).to be_nil
      expect(authenticator.call(request_for)).to be_nil
      expect(authenticator.call(request_for(authorization: 'Bearer '))).to be_nil
      expect(authenticator.call(request_for(authorization: 'Basic s3cret'))).to be_nil
    end

    it 'refuses a token that merely shares a prefix' do
      expect(authenticator.call(request_for(authorization: 'Bearer s3cretX'))).to be_nil
      expect(authenticator.call(request_for(authorization: 'Bearer s3cre'))).to be_nil
    end

    it 'can read another header and return a caller-supplied principal' do
      custom = described_class.new(token: 'abc', header: 'X-Mcp-Token', principal: :owner)
      env = Rack::MockRequest.env_for('/mcp')
      env['HTTP_X_MCP_TOKEN'] = 'Bearer abc'

      expect(custom.call(Rack::Request.new(env))).to eq(:owner)
    end

    it 'refuses to be constructed without a secret' do
      expect { described_class.new(token: '') }.to raise_error(ArgumentError)
      expect { described_class.new(token: nil) }.to raise_error(ArgumentError)
    end
  end

  describe described_class::IpAllowlist do
    subject(:allowlist) { described_class.new(%w[127.0.0.0/8 10.0.0.0/8]) }

    it 'accepts an address inside a range' do
      expect(allowlist.call(request_for(ip: '10.1.2.3'))).to be(true)
    end

    it 'refuses an address outside every range' do
      expect(allowlist.call(request_for(ip: '203.0.113.9'))).to be_nil
    end

    # ::ffff:127.0.0.1 should match an IPv4 range, as a caller would expect.
    it 'compares IPv4-mapped IPv6 addresses as IPv4' do
      expect(allowlist.call(request_for(ip: '::ffff:127.0.0.1'))).to be(true)
    end

    it 'accepts a comma-separated string and ignores unparseable entries' do
      lenient = described_class.new('10.0.0.0/8, not-an-ip , 192.168.0.0/16')

      expect(lenient.call(request_for(ip: '192.168.1.5'))).to be(true)
      expect(lenient.call(request_for(ip: '172.16.0.1'))).to be_nil
    end

    it 'refuses an unparseable client address' do
      expect(allowlist.call(request_for(ip: 'garbage'))).to be_nil
    end

    it 'refuses to be constructed with no usable range' do
      expect { described_class.new([]) }.to raise_error(ArgumentError)
      expect { described_class.new('nonsense') }.to raise_error(ArgumentError)
    end
  end

  describe described_class::Chain do
    let(:allowlist) { FastMcp::Authentication::IpAllowlist.new('127.0.0.0/8') }
    let(:token) { FastMcp::Authentication::TokenAuthenticator.new(token: 's3cret', principal: :owner) }

    subject(:chain) { described_class.new(allowlist, token) }

    it 'accepts only when every link accepts' do
      expect(chain.call(request_for(authorization: 'Bearer s3cret'))).to eq(:owner)
    end

    it 'refuses when the address is wrong, even with a good token' do
      expect(chain.call(request_for(authorization: 'Bearer s3cret', ip: '203.0.113.9'))).to be_nil
    end

    it 'refuses when the token is wrong, even from an allowed address' do
      expect(chain.call(request_for(authorization: 'Bearer wrong'))).to be_nil
    end

    # A link returning plain true vouches for the request without naming anyone, so the most
    # specific principal wins.
    it 'returns the most specific principal produced' do
      expect(described_class.new(allowlist).call(request_for)).to be(true)
    end

    it 'stops at the first refusal' do
      later = instance_double(FastMcp::Authentication::TokenAuthenticator)
      refusing = ->(_request) { nil }

      expect(later).not_to receive(:call)
      expect(described_class.new(refusing, later).call(request_for)).to be_nil
    end

    it 'refuses to be constructed empty' do
      expect { described_class.new }.to raise_error(ArgumentError)
    end
  end
end
