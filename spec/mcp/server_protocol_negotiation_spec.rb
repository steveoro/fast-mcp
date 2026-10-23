# frozen_string_literal: true

RSpec.describe FastMcp::Server, '#negotiate_protocol_version' do
  let(:server) { described_class.new(name: 't', version: '0', logger: Logger.new(nil)) }

  # Table from §1.9: supported → echo; anything else → newest handshake version (2025-11-25).
  {
    '2024-11-05' => '2024-11-05',
    '2025-03-26' => '2025-03-26',
    '2025-06-18' => '2025-06-18',
    '2025-11-25' => '2025-11-25',
    '2026-07-28' => '2025-11-25', # modern era: no handshake
    '2099-01-01' => '2025-11-25', # future garbage
    'garbage'    => '2025-11-25',
    nil          => '2025-11-25',
    42           => '2025-11-25'
  }.each do |asked, answered|
    it "answers #{answered} when asked #{asked.inspect}" do
      expect(server.negotiate_protocol_version(asked)).to eq(answered)
    end
  end

  describe 'with protocol_versions: override (§1.1)' do
    it 'honours the cap: falls back to the newest allowed version' do
      capped = described_class.new(name: 't', version: '0',
                                   protocol_versions: %w[2025-03-26 2024-11-05],
                                   logger: Logger.new(nil))
      expect(capped.negotiate_protocol_version('2025-11-25')).to eq('2025-03-26')
      expect(capped.negotiate_protocol_version('2025-03-26')).to eq('2025-03-26')
      expect(capped.negotiate_protocol_version('2024-11-05')).to eq('2024-11-05')
    end

    it 'raises ArgumentError for an empty list' do
      expect do
        described_class.new(name: 't', version: '0', protocol_versions: [], logger: Logger.new(nil))
      end.to raise_error(ArgumentError, /must not be empty/)
    end

    it 'raises ArgumentError for modern-era versions (>= 2026-07-28)' do
      expect do
        described_class.new(name: 't', version: '0',
                            protocol_versions: %w[2026-07-28],
                            logger: Logger.new(nil))
      end.to raise_error(ArgumentError, /modern-era/)
    end

    it 'raises ArgumentError for non-YYYY-MM-DD strings' do
      expect do
        described_class.new(name: 't', version: '0',
                            protocol_versions: %w[latest],
                            logger: Logger.new(nil))
      end.to raise_error(ArgumentError, /YYYY-MM-DD/)
    end
  end

  describe '#supported_protocol_version?' do
    it 'returns true for versions in the default list' do
      %w[2024-11-05 2025-03-26 2025-06-18 2025-11-25].each do |v|
        expect(server.supported_protocol_version?(v)).to be(true), "expected #{v} to be supported"
      end
    end

    it 'returns false for unsupported versions' do
      %w[2026-07-28 2099-01-01 garbage].each do |v|
        expect(server.supported_protocol_version?(v)).to be(false), "expected #{v} to be unsupported"
      end
    end
  end

  describe 'initialize handshake (via handle_request)' do
    let(:transport) { instance_double('Transport', send_message: nil) }

    before { server.transport = transport }

    it 'echoes a supported version back to the client' do
      response = nil
      allow(transport).to receive(:send_message) { |msg| response = msg }
      server.handle_request(
        JSON.generate(jsonrpc: '2.0', id: 1, method: 'initialize',
                      params: { protocolVersion: '2025-03-26', capabilities: {}, clientInfo: {} })
      )
      expect(response[:result][:protocolVersion]).to eq('2025-03-26')
    end

    it 'returns the newest handshake version when the requested version is modern/unsupported' do
      response = nil
      allow(transport).to receive(:send_message) { |msg| response = msg }
      server.handle_request(
        JSON.generate(jsonrpc: '2.0', id: 1, method: 'initialize',
                      params: { protocolVersion: '2026-07-28', capabilities: {}, clientInfo: {} })
      )
      expect(response[:result][:protocolVersion]).to eq('2025-11-25')
    end

    it 'sets @negotiated_protocol_version after a successful handshake' do
      allow(transport).to receive(:send_message)
      server.handle_request(
        JSON.generate(jsonrpc: '2.0', id: 1, method: 'initialize',
                      params: { protocolVersion: '2025-06-18', capabilities: {}, clientInfo: {} })
      )
      expect(server.negotiated_protocol_version).to eq('2025-06-18')
    end
  end
end
