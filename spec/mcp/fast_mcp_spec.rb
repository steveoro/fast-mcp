# frozen_string_literal: true

RSpec.describe FastMcp do
  describe '.mount_in_rails' do
    let(:middleware) { instance_double('MiddlewareStack') }
    let(:app) { instance_double('RailsApplication', middleware: middleware) }
    let(:logger) { Logger.new(nil) }

    it 'does not inject loopback addresses when a non-local mount omits allowed_ips' do
      expect(middleware).to receive(:use) do |_transport, _server, options|
        expect(options).to include(localhost_only: false)
        expect(options).not_to have_key(:allowed_ips)
      end

      described_class.mount_in_rails(
        app,
        name: 'test',
        logger: logger,
        allowed_origins: [],
        localhost_only: false
      )
    end

    it 'passes an explicit IP policy through unchanged' do
      expect(middleware).to receive(:use) do |_transport, _server, options|
        expect(options[:allowed_ips]).to eq(['10.0.0.0/8'])
      end

      described_class.mount_in_rails(
        app,
        name: 'test',
        logger: logger,
        allowed_origins: [],
        localhost_only: false,
        allowed_ips: ['10.0.0.0/8']
      )
    end
  end
end
