# frozen_string_literal: true

require 'stringio'
require 'rack'

RSpec.describe 'FastMcp::Transports::RackTransport with filtering' do
  let(:server) { FastMcp::Server.new(name: 'test-server', version: '1.0.0', logger: Logger.new(nil)) }
  let(:app) { ->(_env) { [200, { 'Content-Type' => 'text/plain' }, ['OK']] } }
  let(:transport) { FastMcp::Transports::RackTransport.new(app, server) }
  
  # Define test tools
  let(:admin_tool) do
    Class.new(FastMcp::Tool) do
      tool_name 'admin_tool'
      description 'Admin tool'
      tags :admin
      
      def call
        "Admin action"
      end
    end
  end
  
  let(:user_tool) do
    Class.new(FastMcp::Tool) do
      tool_name 'user_tool' 
      description 'User tool'
      tags :user
      
      def call
        "User action"
      end
    end
  end
  
  before do
    server.register_tools(admin_tool, user_tool)
    transport.start
  end
  
  describe 'per-request server filtering' do
    context 'when server has filters' do
      before do
        server.filter_tools do |request, tools|
          role = request.params['role']
          role == 'admin' ? tools : tools.reject { |t| t.tags.include?(:admin) }
        end
      end
      
      # Filters are applied in place now. Cloning the server per request reassigned
      # `tool.server` globally, which corrupted per-request contexts.
      it 'serves the request from the original server, without cloning' do
        env = {
          'PATH_INFO' => '/mcp/messages',
          'REQUEST_METHOD' => 'POST',
          'QUERY_STRING' => 'role=user',
          'REMOTE_ADDR' => '127.0.0.1',
          'rack.input' => StringIO.new('{"jsonrpc":"2.0","method":"ping","id":1}')
        }

        transport.call(env)

        expect(admin_tool.server).to equal(server)
      end

      it 'still applies the filter to tools/list' do
        env = {
          'PATH_INFO' => '/mcp/messages',
          'REQUEST_METHOD' => 'POST',
          'QUERY_STRING' => 'role=user',
          'REMOTE_ADDR' => '127.0.0.1',
          'rack.input' => StringIO.new('{"jsonrpc":"2.0","method":"tools/list","id":1}')
        }
        broadcast = nil
        allow(transport).to receive(:send_message) { |message| broadcast = message }

        transport.call(env)

        names = broadcast.dig(:result, :tools).map { |tool| tool[:name] }
        expect(names).to eq(['user_tool'])
      end
    end
    
    context 'when using SERVER_ENV_KEY' do
      let(:custom_server) { FastMcp::Server.new(name: 'custom-server', version: '1.0.0', logger: Logger.new(nil)) }
      
      before do
        custom_server.register_tool(user_tool) # Only register user tool
      end
      
      it 'uses server from env when provided' do
        env = {
          'PATH_INFO' => '/mcp/messages',
          'REQUEST_METHOD' => 'POST',
          'REMOTE_ADDR' => '127.0.0.1',
          'rack.input' => StringIO.new('{"jsonrpc":"2.0","method":"ping","id":1}'),
          FastMcp::Transports::RackTransport::SERVER_ENV_KEY => custom_server
        }
        
        expect(custom_server).to receive(:handle_request).and_call_original

        transport.call(env)
      end
    end
  end
  
  describe 'integration with server filtering' do
    it 'filters tools correctly' do
      # Set up filtering
      server.filter_tools do |request, tools|
        role = request.params['role']
        role == 'admin' ? tools : tools.reject { |t| t.tags.include?(:admin) }
      end
      
      mock_request = double('request', params: { 'role' => 'user' })
      visible = server.visible_tools(mock_request)

      expect(visible.map(&:tool_name)).to eq(['user_tool'])
      expect(server.tools.keys).to contain_exactly('admin_tool', 'user_tool')
    end
  end
end 