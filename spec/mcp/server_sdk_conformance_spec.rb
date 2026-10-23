# frozen_string_literal: true

# §1.14.1-3 and §1.14.5: conformance with the MCP Ruby SDK 1.8.1 (D-14…D-17).

RSpec.describe FastMcp::Server, 'Ruby SDK 1.8.1 conformance (§1.14)' do
  let(:logger) { Logger.new(nil) }
  let(:capabilities) { {} }
  let(:server) { described_class.new(name: 't', version: '0', logger: logger, capabilities: capabilities) }
  let(:transport) { instance_double('Transport', send_message: nil) }
  let(:captured) { [] }
  let(:calls) { [] }
  let(:tool_class) do
    recorder = calls
    Class.new(FastMcp::Tool) do
      tool_name 'synth_widget'
      description 'Records that it ran'
      define_method(:call) { recorder << :ran && 'ran' }
    end
  end

  before do
    server.transport = transport
    allow(transport).to receive(:send_message) { |msg| captured << msg }
    server.register_tool(tool_class)
  end

  def request(hash)
    server.handle_request(JSON.generate(hash))
  end

  describe 'explicit null id (§1.14.1, #612)' do
    it 'refuses a request with "id": null and never runs the tool' do
      request(jsonrpc: '2.0', id: nil, method: 'tools/call', params: { name: 'synth_widget', arguments: {} })

      expect(captured.last[:error]).to eq(code: -32_600, message: 'Invalid Request', data: 'Request ID must not be null')
      expect(captured.last).not_to have_key(:id)
      expect(calls).to be_empty
    end

    it 'drops an id-less request method as a notification: no reply, tool not run' do
      request(jsonrpc: '2.0', method: 'tools/call', params: { name: 'synth_widget', arguments: {} })

      expect(captured).to be_empty
      expect(calls).to be_empty
    end

    it 'never answers a client response, even one with "id": null' do
      request(jsonrpc: '2.0', id: nil, error: { code: -32_700, message: 'Parse error' })
      request(jsonrpc: '2.0', id: nil, result: {})

      expect(captured).to be_empty
    end

    it 'still runs the tool for a valid id' do
      request(jsonrpc: '2.0', id: 7, method: 'tools/call', params: { name: 'synth_widget', arguments: {} })

      expect(captured.last[:id]).to eq(7)
      expect(calls).to eq([:ran])
    end
  end

  describe 'list_changed notifications (§1.14.2-3)' do
    before { server.instance_variable_set(:@client_initialized, true) }

    it 'sends notifications/resources/list_changed' do
      server.send(:notify_resource_list_changed)

      expect(captured.last[:method]).to eq('notifications/resources/list_changed')
    end

    context 'when listChanged is not advertised' do
      let(:capabilities) { { resources: { subscribe: false, listChanged: false }, tools: { listChanged: false } } }

      it 'suppresses both list-changed notifications' do
        server.send(:notify_resource_list_changed)
        server.send(:notify_tool_list_changed)

        expect(captured).to be_empty
      end
    end
  end

  describe 'resources/subscribe gating (§1.14.3)' do
    before { server.instance_variable_set(:@client_initialized, true) }

    context 'when resources.subscribe is not advertised' do
      let(:capabilities) { { resources: { subscribe: false, listChanged: false } } }

      %w[resources/subscribe resources/unsubscribe].each do |method|
        it "answers #{method} with -32601" do
          request(jsonrpc: '2.0', id: 3, method: method, params: { uri: 'counter' })

          expect(captured.last).to include(id: 3, error: { code: -32_601, message: "Method not found: #{method}" })
        end
      end
    end

    it 'serves resources/unsubscribe when subscribe is advertised (the default)' do
      request(jsonrpc: '2.0', id: 4, method: 'resources/unsubscribe', params: { uri: 'counter' })

      expect(captured.last).to include(id: 4, result: { unsubscribed: true })
    end
  end

  describe 'error id member (§1.14.5, D-17)' do
    def error_for(raw)
      server.handle_request(raw)
      captured.last
    end

    it('echoes an integer id') { expect(error_for('{"jsonrpc":"2.0","id":5,"method":"nope"}')).to include(id: 5) }

    it 'echoes a string id' do
      expect(error_for('{"jsonrpc":"2.0","id":"a-1","method":"nope"}')).to include(id: 'a-1')
    end

    it 'omits a string id with invalid encoding' do
      response = error_for(%({"jsonrpc":"2.0","id":"\xFF","method":"nope"}).b)

      expect(response[:error][:code]).to be_between(-32_700, -32_600)
      expect(response).not_to have_key(:id)
    end

    it('omits a null id') { expect(error_for('{"jsonrpc":"2.0","id":null,"method":"nope"}')).not_to have_key(:id) }
    it('omits the id on a parse error') { expect(error_for('{"jsonrpc":')).not_to have_key(:id) }

    it 'omits an object id' do
      expect(error_for('{"jsonrpc":"2.0","id":{"x":1},"method":"nope"}')).not_to have_key(:id)
    end

    it 'builds the same shape through FastMcp::JsonRpc' do
      expect(FastMcp::JsonRpc.error_response(-32_600, 'Invalid Request', true))
        .to eq(jsonrpc: '2.0', error: { code: -32_600, message: 'Invalid Request' })
    end
  end

  describe 'subscribe before notifications/initialized' do
    %w[resources/subscribe resources/unsubscribe].each do |method|
      it "answers #{method} with -32600 instead of leaving the request unanswered" do
        request(jsonrpc: '2.0', id: 8, method: method, params: { uri: 'counter' })

        expect(captured.last).to include(id: 8, error: { code: -32_600, message: 'Invalid Request: client not initialized' })
      end
    end
  end
end
