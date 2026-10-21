# frozen_string_literal: true

# §1.2 / §1.9: stdio transport line-length cap.
# An over-limit line yields -32600 and is discarded; the next valid line is still processed.
#
# Design: StdioTransport reads from a StringIO; start() returns immediately at EOF.
# We call start() synchronously (no thread) — it exits as soon as it drains the input.

RSpec.describe FastMcp::Transports::StdioTransport, 'line length cap (§1.2/§1.9)' do
  let(:logger) { Logger.new(nil) }

  let(:server) do
    instance_double(
      FastMcp::Server,
      logger: logger,
      transport: nil,
      'transport=' => nil,
      contains_filters?: false,
      respond_to?: false
    )
  end

  # Build a transport with fixed input/output StringIOs.
  # @return [transport, output_io]
  def make_transport(input_string, limit:)
    input  = StringIO.new(input_string)
    output = StringIO.new
    t = described_class.new(server, logger: logger, input: input, output: output,
                             max_request_bytes: limit)
    [t, output]
  end

  def messages_from(output_io)
    output_io.rewind
    output_io.read.split("\n").filter_map { |l| JSON.parse(l) rescue nil } # rubocop:disable Style/RescueModifier
  end

  # ── Over-limit line → -32600 ──────────────────────────────────────────────

  describe 'over-limit line' do
    before do
      allow(server).to receive(:handle_request)
    end

    it 'writes a -32600 error response for an oversized line' do
      limit = 50
      oversized = 'x' * (limit + 10)
      transport_obj, output = make_transport("#{oversized}\n", limit: limit)
      transport_obj.start
      msgs = messages_from(output)
      expect(msgs.size).to eq(1)
      expect(msgs.first['error']['code']).to eq(-32_600)
    end

    it 'does not forward the over-limit payload to handle_request' do
      limit = 40
      oversized = 'x' * (limit + 10)
      transport_obj, _ = make_transport("#{oversized}\n", limit: limit)
      transport_obj.start
      expect(server).not_to have_received(:handle_request)
    end
  end

  # ── Over-limit line followed by valid line → recovery ────────────────────

  describe 'recovery after an over-limit line' do
    before do
      allow(server).to receive(:handle_request)
    end

    it 'processes the next valid line after discarding the over-limit one' do
      limit      = 50
      oversized  = 'x' * (limit + 10)
      valid_line = JSON.generate(jsonrpc: '2.0', id: 2, method: 'ping')
      combined   = "#{oversized}\n#{valid_line}\n"

      transport_obj, output = make_transport(combined, limit: limit)
      transport_obj.start

      expect(server).to have_received(:handle_request).with(valid_line, anything)
      # The output contains one error (oversized) and then whatever the server response is.
      msgs = messages_from(output)
      expect(msgs.first['error']['code']).to eq(-32_600)
    end
  end

  # ── Within-limit line passes through ──────────────────────────────────────

  describe 'within-limit line' do
    before { allow(server).to receive(:handle_request) }

    it 'forwards the body to server#handle_request' do
      limit     = 200
      ping_line = JSON.generate(jsonrpc: '2.0', id: 1, method: 'ping')
      transport_obj, _ = make_transport("#{ping_line}\n", limit: limit)
      transport_obj.start
      expect(server).to have_received(:handle_request).with(ping_line, anything)
    end
  end

  # ── No cap when max_request_bytes is nil ──────────────────────────────────

  describe 'nil limit (unlimited)' do
    before { allow(server).to receive(:handle_request) }

    it 'forwards an arbitrarily long line' do
      ping = JSON.generate(jsonrpc: '2.0', id: 1, method: 'ping', extra: 'a' * 10_000)
      transport_obj, _ = make_transport("#{ping}\n", limit: nil)
      transport_obj.start
      expect(server).to have_received(:handle_request).with(ping, anything)
    end
  end

  # ── input: / output: options ──────────────────────────────────────────────

  describe 'input: / output: options' do
    it 'reads from the custom input IO' do
      allow(server).to receive(:handle_request)
      ping = JSON.generate(jsonrpc: '2.0', id: 3, method: 'ping')
      custom_input  = StringIO.new("#{ping}\n")
      custom_output = StringIO.new
      transport_obj = described_class.new(server, logger: logger,
                                          input: custom_input, output: custom_output,
                                          max_request_bytes: nil)
      transport_obj.start
      expect(server).to have_received(:handle_request).with(ping, anything)
    end

    it 'defaults to $stdin / $stdout when no IO is provided' do
      transport_obj = described_class.new(server, logger: logger)
      # nil means "resolve $stdin/$stdout dynamically at I/O time" (so callers can swap the globals)
      expect(transport_obj.instance_variable_get(:@input)).to be_nil
      expect(transport_obj.instance_variable_get(:@output)).to be_nil
    end
  end
end
