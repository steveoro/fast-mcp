# frozen_string_literal: true

RSpec.describe FastMcp::Server do
  let(:server) { described_class.new(name: 'test-server', version: '1.0.0', logger: Logger.new(nil)) }

  describe '#initialize' do
    it 'creates a server with the given name and version' do
      expect(server.name).to eq('test-server')
      expect(server.version).to eq('1.0.0')
      expect(server.tools).to be_empty
      expect(server.prompts).to be_empty
      expect(server.capabilities).to include(
        tools: { listChanged: true },
        prompts: { listChanged: false }
      )
    end
  end

  describe 'tool list-change notifications' do
    let(:transport) { instance_double('Transport', send_message: nil) }
    let(:tool_class) do
      Class.new(FastMcp::Tool) do
        tool_name 'notified-tool'
      end
    end

    before do
      server.transport = transport
      server.instance_variable_set(:@client_initialized, true)
    end

    it 'notifies initialized clients when tools are registered or removed' do
      server.register_tool(tool_class)
      server.remove_tool('notified-tool')

      expect(transport).to have_received(:send_message).with(
        jsonrpc: '2.0',
        method: 'notifications/tools/list_changed',
        params: {}
      ).twice
    end

    it 'returns false when removing an unknown tool' do
      expect(server.remove_tool('missing')).to be(false)
      expect(transport).not_to have_received(:send_message)
    end
  end

  describe '#with_request_context' do
    let(:default_transport) { instance_double('DefaultTransport', send_message: nil) }
    let(:request_transport) { instance_double('RequestTransport', send_message: nil) }

    before { server.transport = default_transport }

    it 'routes responses to the request transport and clears context afterward' do
      server.with_request_context(transport: request_transport, session_id: 'session-1') do
        expect(server.current_request_context).to include(session_id: 'session-1')
        server.send(:send_response, jsonrpc: '2.0', id: 1, result: {})
      end

      expect(request_transport).to have_received(:send_message)
      expect(default_transport).not_to have_received(:send_message)
      expect(server.current_request_context).to be_nil
    end

    it 'restores nested context even when dispatch raises' do
      expect do
        server.with_request_context(transport: default_transport, name: 'outer') do
          server.with_request_context(transport: request_transport, name: 'inner') do
            expect(server.current_request_context[:name]).to eq('inner')
            raise 'boom'
          end
        end
      end.to raise_error('boom')

      expect(server.current_request_context).to be_nil
    end
  end

  describe '#register_tool' do
    it 'registers a tool with the server' do
      test_tool_class = Class.new(FastMcp::Tool) do
        def self.name
          'test-tool'
        end

        def self.description
          'A test tool'
        end

        def call(**_args)
          'Hello, World!'
        end
      end

      server.register_tool(test_tool_class)

      expect(server.tools['test-tool']).to eq(test_tool_class)
    end
  end

  describe '#handle_request' do
    let(:test_tool_class) do
      Class.new(FastMcp::Tool) do
        def self.name
          'test-tool'
        end

        def self.description
          'A test tool'
        end

        arguments do
          required(:name).filled(:string).description('User name')
        end

        def call(name:)
          "Hello, #{name}!"
        end
      end
    end

    let(:profile_tool_class) do
      Class.new(FastMcp::Tool) do
        def self.name
          'profile-tool'
        end

        def self.description
          'A tool for handling user profiles'
        end

        arguments do
          required(:user).hash do
            required(:first_name).filled(:string).description('First name of the user')
            required(:last_name).filled(:string).description('Last name of the user')
          end
        end

        def call(user:)
          "#{user[:first_name]} #{user[:last_name]}"
        end
      end
    end

    let(:recall_prompt_class) do
      Class.new(FastMcp::Prompt) do
        prompt_name 'recall'
        description 'Recall knowledge'
        argument :topic, description: 'Subject', required: true

        def messages(topic:)
          [{ role: 'user', content: { type: 'text', text: "Recall #{topic}" } }]
        end
      end
    end

    let(:structured_tool_class) do
      Class.new(FastMcp::Tool) do
        tool_name 'structured-tool'
        description 'Returns structured data'
        output_schema(
          type: 'object',
          properties: { answer: { type: 'string' } },
          required: ['answer']
        )

        def call
          { answer: 'forty-two' }
        end
      end
    end

    before do
      # Register the test tools
      server.register_tool(test_tool_class)
      server.register_tool(profile_tool_class)

      # Stub the send_response method
      allow(server).to receive(:send_response)
    end

    context 'with a ping request' do
      it 'responds with an empty result' do
        request = { jsonrpc: '2.0', method: 'ping', id: 1 }.to_json

        expect(server).to receive(:send_result).with({}, 1)
        server.handle_request(request)
      end
    end

    context 'with a ping response' do
      it 'responds with an empty result' do
        request = { result: {}, id: 1, jsonrpc: '2.0' }.to_json
        expect(server).not_to receive(:send_result)

        response = server.handle_request(request)
        expect(response).to be_nil
      end
    end

    context 'with a notifications/initialized request' do
      it 'responds with nil' do
        request = { jsonrpc: '2.0', method: 'notifications/initialized' }.to_json

        response = server.handle_request(request)
        expect(response).to be_nil
      end
    end

    context 'with an initialize request' do
      it 'responds with the server info' do
        request = { jsonrpc: '2.0', method: 'initialize', id: 1 }.to_json

        expect(server).to receive(:send_result).with({
                                                       protocolVersion: FastMcp::Server::PROTOCOL_VERSION,
                                                       capabilities: server.capabilities,
                                                       serverInfo: {
                                                         name: server.name,
                                                         version: server.version
                                                       }
                                                     }, 1)
        server.handle_request(request)
      end
    end

    context 'with a tools/list request' do
      it 'responds with a list of tools' do
        request = { jsonrpc: '2.0', method: 'tools/list', id: 1 }.to_json

        expect(server).to receive(:send_result) do |result, id|
          expect(id).to eq(1)
          expect(result[:tools]).to be_an(Array)
          expect(result[:tools].length).to eq(2)

          # Test the simple tool
          test_tool = result[:tools].find { |t| t[:name] == 'test-tool' }
          expect(test_tool[:description]).to eq('A test tool')
          expect(test_tool[:inputSchema]).to be_a(Hash)
          expect(test_tool[:inputSchema][:properties][:name][:description]).to eq('User name')

          # Test the tool with nested properties
          profile_tool = result[:tools].find { |t| t[:name] == 'profile-tool' }
          expect(profile_tool[:description]).to eq('A tool for handling user profiles')
          expect(profile_tool[:inputSchema][:properties][:user][:type]).to eq('object')
          # We no longer expect descriptions on nested fields since they aren't being passed through
          expect(profile_tool[:inputSchema][:properties][:user][:properties]).to have_key(:first_name)
          expect(profile_tool[:inputSchema][:properties][:user][:properties]).to have_key(:last_name)
        end

        server.handle_request(request)
      end
      
      context 'with tool annotations' do
        let(:annotated_tool_class) do
          Class.new(FastMcp::Tool) do
            def self.name
              'annotated-tool'
            end

            def self.description
              'A tool with annotations'
            end
            
            annotations(
              title: 'Web Search Tool',
              read_only_hint: true,
              open_world_hint: true
            )

            def call(**_args)
              'Searching...'
            end
          end
        end
        
        before do
          server.register_tool(annotated_tool_class)
        end
        
        it 'includes annotations in the tools list' do
          request = { jsonrpc: '2.0', method: 'tools/list', id: 1 }.to_json

          expect(server).to receive(:send_result) do |result, id|
            expect(id).to eq(1)
            
            annotated_tool = result[:tools].find { |t| t[:name] == 'annotated-tool' }
            expect(annotated_tool[:annotations]).to eq({
              title: 'Web Search Tool',
              readOnlyHint: true,
              openWorldHint: true
            })
          end

          server.handle_request(request)
        end
      end
      
      context 'with tool without annotations' do
        it 'does not include annotations field' do
          request = { jsonrpc: '2.0', method: 'tools/list', id: 1 }.to_json

          expect(server).to receive(:send_result) do |result, id|
            expect(id).to eq(1)
            
            test_tool = result[:tools].find { |t| t[:name] == 'test-tool' }
            expect(test_tool).not_to have_key(:annotations)
          end

          server.handle_request(request)
        end
      end

      it 'includes outputSchema only for tools that declare one' do
        server.register_tool(structured_tool_class)
        request = { jsonrpc: '2.0', method: 'tools/list', id: 1 }.to_json

        expect(server).to receive(:send_result) do |result, _id|
          structured = result[:tools].find { |tool| tool[:name] == 'structured-tool' }
          plain = result[:tools].find { |tool| tool[:name] == 'test-tool' }
          expect(structured[:outputSchema]).to eq(structured_tool_class.output_schema_to_json)
          expect(plain).not_to have_key(:outputSchema)
        end

        server.handle_request(request)
      end
    end

    context 'with a tools/call request' do
      it 'calls the specified tool and returns the result' do
        request = {
          jsonrpc: '2.0',
          method: 'tools/call',
          params: {
            name: 'test-tool',
            arguments: { name: 'World' }
          },
          id: 1
        }.to_json

        expect(server).to receive(:send_result).with(
          { content: [{ text: 'Hello, World!', type: 'text' }], isError: false },
          1,
          metadata: {}
        )
        server.handle_request(request)
      end

      it 'calls a tool with nested properties' do
        request = {
          jsonrpc: '2.0',
          method: 'tools/call',
          params: {
            name: 'profile-tool',
            arguments: {
              user: {
                first_name: 'John',
                last_name: 'Doe'
              }
            }
          },
          id: 1
        }.to_json

        expect(server).to receive(:send_result).with(
          { content: [{ text: 'John Doe', type: 'text' }], isError: false },
          1,
          metadata: {}
        )
        server.handle_request(request)
      end

      it "returns an error if the tool doesn't exist" do
        request = {
          jsonrpc: '2.0',
          method: 'tools/call',
          params: {
            name: 'non-existent-tool',
            arguments: {}
          },
          id: 1
        }.to_json

        expect(server).to receive(:send_error).with(-32_602, 'Tool not found: non-existent-tool', 1)
        server.handle_request(request)
      end

      it 'returns an error if the tool name is missing' do
        request = {
          jsonrpc: '2.0',
          method: 'tools/call',
          params: {
            arguments: {}
          },
          id: 1
        }.to_json

        expect(server).to receive(:send_error).with(-32_602, 'Invalid params: missing tool name', 1)
        server.handle_request(request)
      end

      it 'emits dual structured and JSON text content for schema-enabled tools' do
        server.register_tool(structured_tool_class)
        request = {
          jsonrpc: '2.0',
          method: 'tools/call',
          params: { name: 'structured-tool', arguments: {} },
          id: 2
        }.to_json

        expect(server).to receive(:send_result).with(
          {
            content: [{ type: 'text', text: '{"answer":"forty-two"}' }],
            structuredContent: { 'answer' => 'forty-two' },
            isError: false
          },
          2,
          metadata: {}
        )

        server.handle_request(request)
      end

      it 'preserves custom content result hashes even when a schema exists' do
        custom_tool = Class.new(structured_tool_class) do
          tool_name 'custom-content-tool'

          def call
            { content: [{ type: 'text', text: 'custom' }], isError: false }
          end
        end
        server.register_tool(custom_tool)

        expect(server).to receive(:send_result).with(
          { content: [{ type: 'text', text: 'custom' }], isError: false },
          3,
          metadata: {}
        )
        server.handle_request(
          {
            jsonrpc: '2.0',
            method: 'tools/call',
            params: { name: 'custom-content-tool', arguments: {} },
            id: 3
          }.to_json
        )
      end
    end

    context 'with prompt requests' do
      before { server.register_prompt(recall_prompt_class) }

      it 'lists registered prompts' do
        expect(server).to receive(:send_result) do |result, id|
          expect(id).to eq(1)
          expect(result[:prompts]).to eq([ recall_prompt_class.metadata ])
        end

        server.handle_request({ jsonrpc: '2.0', method: 'prompts/list', id: 1 }.to_json)
      end

      it 'renders a prompt with arguments' do
        expect(server).to receive(:send_result).with(
          {
            description: 'Recall knowledge',
            messages: [{ role: 'user', content: { type: 'text', text: 'Recall GraphMem' } }]
          },
          2
        )

        server.handle_request(
          {
            jsonrpc: '2.0',
            method: 'prompts/get',
            params: { name: 'recall', arguments: { topic: 'GraphMem' } },
            id: 2
          }.to_json
        )
      end

      it 'rejects missing prompt arguments and unknown prompts' do
        expect(server).to receive(:send_error).with(
          -32_602,
          'Invalid params: missing required prompt arguments: topic',
          3
        )
        server.handle_request(
          { jsonrpc: '2.0', method: 'prompts/get', params: { name: 'recall' }, id: 3 }.to_json
        )

        expect(server).to receive(:send_error).with(-32_602, 'Prompt not found: missing', 4)
        server.handle_request(
          { jsonrpc: '2.0', method: 'prompts/get', params: { name: 'missing' }, id: 4 }.to_json
        )
      end
    end

    context 'with an invalid request' do
      it 'returns an error for an unknown method' do
        request = { jsonrpc: '2.0', method: 'unknown', id: 1 }.to_json

        expect(server).to receive(:send_error).with(-32_601, 'Method not found: unknown', 1)
        server.handle_request(request)
      end

      it 'returns an error for an invalid JSON-RPC request' do
        request = { id: 1 }.to_json

        expect(server).to receive(:send_error).with(-32_600, 'Invalid Request', 1)
        server.handle_request(request)
      end

      it 'returns an error for an invalid JSON request' do
        request = 'invalid json'

        expect(server).to receive(:send_error).with(-32_600, 'Invalid Request', nil)
        server.handle_request(request)
      end
    end

    context 'with an error result' do
      let(:on_error_result) { ->(message) { message } }

      before {
        server.on_error_result(&on_error_result)
        allow_any_instance_of(test_tool_class).to receive(:call).and_raise('test error')
      }

      it 'calls the on_error_result block' do
        request = {
          jsonrpc: '2.0',
          method: 'tools/call',
          params: {
            name: 'test-tool',
            arguments: { name: 'World' }
          },
          id: 1
        }.to_json

        expect(on_error_result).to receive(:call).with(/^test error, /)
        server.handle_request(request)
      end
    end
  end
end
