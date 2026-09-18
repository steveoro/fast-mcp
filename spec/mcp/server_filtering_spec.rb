# frozen_string_literal: true

RSpec.describe 'FastMcp::Server filtering' do
  let(:server) { FastMcp::Server.new(name: 'test-server', version: '1.0.0', logger: Logger.new(nil)) }
  
  # Define test tools with tags
  let(:admin_tool) do
    Class.new(FastMcp::Tool) do
      tool_name 'admin_tool'
      description 'Admin only tool'
      tags :admin, :dangerous
      
      def call
        "Admin action executed"
      end
    end
  end
  
  let(:user_tool) do
    Class.new(FastMcp::Tool) do
      tool_name 'user_tool'
      description 'User tool'
      tags :user, :safe
      
      def call
        "User action executed"
      end
    end
  end
  
  let(:public_tool) do
    Class.new(FastMcp::Tool) do
      tool_name 'public_tool'
      description 'Public tool'
      tags :public
      
      def call
        "Public action executed"
      end
    end
  end
  
  # Define test resources with tags
  let(:admin_resource) do
    Class.new(FastMcp::Resource) do
      uri 'admin/config'
      resource_name 'Admin Config'
      description 'Admin configuration'
      mime_type 'application/json'
      
      def self.tags
        [:admin, :sensitive]
      end
      
      def content
        '{"admin": true}'
      end
    end
  end
  
  let(:user_resource) do
    Class.new(FastMcp::Resource) do
      uri 'user/profile'
      resource_name 'User Profile'
      description 'User profile data'
      mime_type 'application/json'
      
      def self.tags
        [:user]
      end
      
      def content
        '{"user": "data"}'
      end
    end
  end

  before do
    # Register all tools and resources
    server.register_tools(admin_tool, user_tool, public_tool)
    server.register_resources(admin_resource, user_resource)
  end

  describe '#filter_tools' do
    it 'adds tool filters to the server' do
      expect(server.instance_variable_get(:@tool_filters)).to be_empty
      
      server.filter_tools { |_request, tools| tools }
      
      expect(server.instance_variable_get(:@tool_filters).size).to eq(1)
    end
    
    it 'allows multiple filters' do
      server.filter_tools { |_request, tools| tools }
      server.filter_tools { |_request, tools| tools }
      
      expect(server.instance_variable_get(:@tool_filters).size).to eq(2)
    end
  end
  
  describe '#filter_resources' do
    it 'adds resource filters to the server' do
      expect(server.instance_variable_get(:@resource_filters)).to be_empty
      
      server.filter_resources { |_request, resources| resources }
      
      expect(server.instance_variable_get(:@resource_filters).size).to eq(1)
    end
  end
  
  describe '#contains_filters?' do
    it 'returns false when no filters are configured' do
      expect(server.contains_filters?).to be false
    end
    
    it 'returns true when tool filters are configured' do
      server.filter_tools { |_request, tools| tools }
      expect(server.contains_filters?).to be true
    end
    
    it 'returns true when resource filters are configured' do
      server.filter_resources { |_request, resources| resources }
      expect(server.contains_filters?).to be true
    end
  end
  
  describe 'in-place filtering' do
    let(:admin_request) { double('request', params: { 'role' => 'admin' }) }
    let(:user_request) { double('request', params: { 'role' => 'user' }) }

    before do
      server.filter_tools do |req, tools|
        req.params['role'] == 'admin' ? tools : tools.reject { |t| t.tags.include?(:admin) }
      end
    end

    it 'resolves the visible tools per request without building a server' do
      expect(server.visible_tools(admin_request).map(&:tool_name)).to include('admin_tool')
      expect(server.visible_tools(user_request).map(&:tool_name)).not_to include('admin_tool')
    end

    it 'filters nothing when there is no request scope' do
      expect(server.visible_tools(nil).size).to eq(server.tools.size)
    end

    it 'answers tool_visible? consistently with visible_tools' do
      admin_tool = server.tools['admin_tool']

      expect(server.tool_visible?(admin_tool, admin_request)).to be(true)
      expect(server.tool_visible?(admin_tool, user_request)).to be(false)
    end

    # The reason filtering stopped cloning the server. register_tool assigns `tool.server = self`,
    # which is state on the tool *class*, so building a filtered copy for one request silently
    # repointed every other request's tools at it. Request contexts are keyed by server identity,
    # so a tool would then read the wrong context — or none.
    it 'leaves tool.server pointing at the real server, so request contexts stay intact' do
      shared_tool = server.tools['user_tool']

      server.visible_tools(admin_request)
      server.visible_tools(user_request)

      expect(shared_tool.server).to equal(server)

      server.with_request_context(transport: nil, principal: :alice, request: user_request) do
        expect(shared_tool.server.current_request_context[:principal]).to eq(:alice)
      end
    end

    it 'keeps contexts separate across concurrent requests' do
      shared_tool = server.tools['user_tool']
      thread_count = 4
      seen = []
      mutex = Mutex.new
      opened = Queue.new
      release = Queue.new

      threads = Array.new(thread_count) do |index|
        Thread.new do
          principal = :"agent_#{index}"

          server.with_request_context(transport: nil, principal: principal, request: user_request) do
            opened << true
            release.pop # hold the context open until every thread has one
            mutex.synchronize { seen << [principal, shared_tool.server.current_request_context[:principal]] }
          end
        end
      end

      # All four contexts are provably open at the same time before anything reads one.
      thread_count.times { opened.pop }
      thread_count.times { release << true }
      threads.each(&:join)

      expect(seen.size).to eq(thread_count)
      expect(seen).to all(satisfy { |expected, actual| expected == actual })
    end
  end

  describe '#filter_mode' do
    let(:user_request) { double('request', params: { 'role' => 'user' }) }
    let(:transport) { instance_double('Transport', send_message: nil) }

    before do
      server.filter_tools do |req, tools|
        req.params['role'] == 'admin' ? tools : tools.reject { |t| t.tags.include?(:admin) }
      end
      server.transport = transport
    end

    def call_hidden_tool
      captured = { result: nil, error: nil }
      allow(server).to receive(:send_result) { |result, _id| captured[:result] = result }
      allow(server).to receive(:send_error) { |code, message, _id| captured[:error] = [code, message] }

      server.with_request_context(transport: transport, request: user_request) do
        server.handle_request(
          { jsonrpc: '2.0', method: 'tools/call', params: { name: 'admin_tool', arguments: {} }, id: 1 }.to_json
        )
      end

      captured
    end

    it 'defaults to :hide' do
      expect(server.filter_mode).to eq(:hide)
    end

    it 'rejects an unknown mode' do
      expect { server.filter_mode = :maybe }.to raise_error(ArgumentError, /filter_mode/)
    end

    # A filtered tool must not be callable either, or tools/list would be decoration rather than
    # a boundary.
    context 'with :hide' do
      it 'reports a filtered tool as unknown, giving nothing away' do
        expect(call_hidden_tool[:error]).to eq([-32_602, 'Tool not found: admin_tool'])
      end
    end

    context 'with :deny' do
      before { server.filter_mode = :deny }

      it 'reports a filtered tool as a refusal' do
        expect(call_hidden_tool[:error]).to eq([-32_602, 'Unauthorized'])
      end

      it 'routes the refusal through the error formatter when one is configured' do
        server.error_formatter { |message:, tool_name:, error:| JSON.generate(tool: tool_name, klass: error.class.name, message: message) }

        captured = call_hidden_tool

        expect(captured[:error]).to be_nil
        expect(captured[:result][:isError]).to be(true)
        expect(JSON.parse(captured[:result][:content].first[:text])).to include(
          'tool' => 'admin_tool',
          'klass' => 'FastMcp::Server::UnauthorizedError'
        )
      end
    end

    it 'still allows a tool the request can see' do
      captured = { result: nil }
      allow(server).to receive(:send_result) { |result, _id| captured[:result] = result }

      server.with_request_context(transport: transport, request: user_request) do
        server.handle_request(
          { jsonrpc: '2.0', method: 'tools/call', params: { name: 'user_tool', arguments: {} }, id: 1 }.to_json
        )
      end

      expect(captured[:result][:isError]).to be(false)
    end
  end

  # docs/filtering.md presents filtering as permission-based access control and multi-tenancy, so
  # a filtered resource must be unreachable, not merely unlisted. Knowing or guessing a URI must
  # not be enough to read it.
  describe 'resource filtering across every request path' do
    let(:request) { double('request', params: {}) }
    let(:transport) { instance_double('Transport', send_message: nil) }

    let(:secret_resource) do
      Class.new(FastMcp::Resource) do
        uri 'secret/data'
        resource_name 'Secret'
        description 'Filtered out'
        def content = JSON.generate(secret: true)
      end
    end

    let(:secret_template) do
      Class.new(FastMcp::Resource) do
        uri 'secret/{id}'
        resource_name 'Secret template'
        description 'Filtered out'
        def content = JSON.generate(secret: true)
      end
    end

    let(:open_resource) do
      Class.new(FastMcp::Resource) do
        uri 'open/data'
        resource_name 'Open'
        description 'Visible'
        def content = JSON.generate(open: true)
      end
    end

    before do
      server.register_resources(secret_resource, secret_template, open_resource)
      server.transport = transport
      server.instance_variable_set(:@client_initialized, true)
      server.filter_resources do |_req, resources|
        resources.reject { |resource| resource.uri.start_with?('secret/') }
      end
    end

    def dispatch(method_name, params = {})
      captured = { result: nil, error: nil }
      allow(server).to receive(:send_result) { |result, _id| captured[:result] = result }
      allow(server).to receive(:send_error) { |code, message, _id| captured[:error] = [code, message] }

      server.with_request_context(transport: transport, request: request) do
        server.handle_request({ jsonrpc: '2.0', method: method_name, params: params, id: 1 }.to_json)
      end

      captured
    end

    it 'omits a filtered resource from resources/list' do
      uris = dispatch('resources/list')[:result][:resources].map { |r| r[:uri] }

      expect(uris).to include('open/data')
      expect(uris).not_to include('secret/data')
    end

    it 'omits a filtered template from resources/templates/list' do
      templates = dispatch('resources/templates/list')[:result][:resourceTemplates]

      expect(templates.map { |t| t[:uri] }).not_to include('secret/{id}')
    end

    it 'refuses to read a filtered resource by its known URI' do
      captured = dispatch('resources/read', { 'uri' => 'secret/data' })

      expect(captured[:error]).to eq([-32_602, 'Resource not found: secret/data'])
      expect(captured[:result]).to be_nil
    end

    it 'refuses to read through a filtered template' do
      captured = dispatch('resources/read', { 'uri' => 'secret/42' })

      expect(captured[:error]).to eq([-32_602, 'Resource not found: secret/42'])
    end

    it 'refuses to subscribe to a filtered resource' do
      captured = dispatch('resources/subscribe', { 'uri' => 'secret/data' })

      expect(captured[:error]).to eq([-32_602, 'Resource not found: secret/data'])
    end

    # Indistinguishable from a resource that genuinely does not exist, so the filter leaks nothing.
    it 'answers identically for a filtered resource and an unknown one' do
      filtered = dispatch('resources/read', { 'uri' => 'secret/data' })[:error]
      unknown = dispatch('resources/read', { 'uri' => 'nope/at/all' })[:error]

      expect(filtered.first).to eq(unknown.first)
    end

    it 'still serves a visible resource' do
      captured = dispatch('resources/read', { 'uri' => 'open/data' })

      expect(captured[:error]).to be_nil
      expect(captured[:result][:contents].first[:text]).to include('open')
    end
  end

  describe 'when filters are configured but no request is in scope' do
    let(:logger) { instance_double(Logger, warn: nil, debug: nil, info: nil, error: nil) }
    let(:server) { FastMcp::Server.new(name: 'test-server', version: '1.0.0', logger: logger) }

    before do
      server.register_tool(user_tool)
      server.filter_tools { |_req, _tools| [] }
    end

    # Failing open is the dangerous direction: everything keeps working and looks filtered.
    it 'warns, rather than silently serving the unfiltered catalogue' do
      server.visible_tools(nil)

      expect(logger).to have_received(:warn).with(/no request is in scope/)
    end

    it 'warns only once, so it cannot flood the log' do
      3.times { server.visible_tools(nil) }

      expect(logger).to have_received(:warn).once
    end
  end

end 