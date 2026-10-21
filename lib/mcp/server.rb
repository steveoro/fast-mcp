# frozen_string_literal: true

require 'json'
require 'logger'
require 'securerandom'
require 'base64'
require_relative 'transports/stdio_transport'
require_relative 'transports/rack_transport'
require_relative 'transports/authenticated_rack_transport'
require_relative 'logger'
require_relative 'server_filtering'
require_relative 'authentication'

module FastMcp
  class Server # rubocop:disable Metrics/ClassLength
    include ServerFiltering

    # Raised internally when a tool refuses a call via Tool#authorized?. Passed to a configured
    # +error_formatter+ so it can distinguish a refusal from a genuine failure.
    class UnauthorizedError < StandardError; end

    # How a call to a tool the request cannot see is answered.
    #
    # :hide reports it as unknown, giving nothing away about what exists. :deny reports it as a
    # refusal, which is friendlier to an agent that can then explain the situation rather than
    # assume it mistyped a tool name.
    FILTER_MODES = [:hide, :deny].freeze

    attr_reader :name, :version, :tools, :resources, :prompts, :capabilities, :filter_mode

    # Versions reachable through the initialize handshake, NEWEST FIRST (mirrors the TS/Ruby SDKs).
    # 2026-07-28 is never negotiated by initialize: it has no handshake; a client reaches it only
    # via server/discover + per-request _meta envelopes (PR-4). Server.new(protocol_versions:)
    # lets an embedder cap the list (e.g. to %w[2025-03-26 2024-11-05]).
    HANDSHAKE_PROTOCOL_VERSIONS = %w[2025-11-25 2025-06-18 2025-03-26 2024-11-05].freeze

    # Deprecated single-version alias kept for callers that read it directly.
    PROTOCOL_VERSION = '2024-11-05'

    DEFAULT_CAPABILITIES = {
      resources: {
        subscribe: true,
        listChanged: true
      },
      tools: {
        listChanged: true
      },
      prompts: {
        listChanged: false
      }
    }.freeze

    # @param protocol_versions [Array<String>, nil] override the default handshake list; must be
    #   non-empty, all YYYY-MM-DD strings, and none may be >= '2026-07-28' (modern era).
    # @param expose_internal_errors [Boolean] when true, sends the exception message to the client
    #   in internal-error responses. Off by default (backtraces disclose internal structure).
    def initialize(name:, version:, logger: FastMcp::Logger.new, capabilities: {}, # rubocop:disable Metrics/ParameterLists
                   protocol_versions: nil, expose_internal_errors: false)
      @name = name
      @version = version
      @tools = {}
      @resources = []
      @prompts = {}
      @resource_subscriptions = Hash.new { |h, k| h[k] = Set.new }
      @subscriptions_mutex = Mutex.new
      @logger = logger
      @request_id = 0
      @transport_klass = nil
      @transport = nil
      @capabilities = DEFAULT_CAPABILITIES.dup
      @tool_filters = []
      @resource_filters = []
      @prompt_filters = []
      @on_error_result = nil
      @error_formatter = nil
      @filter_mode = :hide
      @expose_internal_errors = expose_internal_errors
      @protocol_versions = validate_protocol_versions!(protocol_versions || HANDSHAKE_PROTOCOL_VERSIONS)

      # Merge with provided capabilities
      @capabilities.merge!(capabilities) if capabilities.is_a?(Hash)
    end
    attr_accessor :transport, :transport_klass, :logger

    # The list of handshake protocol versions this server advertises, newest first.
    attr_reader :protocol_versions

    # The version negotiated in the most recent initialize, or nil before any handshake.
    attr_reader :negotiated_protocol_version

    # Returns true when +version+ is in the supported handshake list (used by transports
    # validating the MCP-Protocol-Version header).
    def supported_protocol_version?(version)
      @protocol_versions.include?(version.to_s)
    end

    # Echoes a supported requested version, or falls back to the newest supported one.
    # A modern version (>= 2026-07-28) or garbage always gets the newest handshake version.
    def negotiate_protocol_version(requested)
      return requested if requested.is_a?(String) && @protocol_versions.include?(requested)

      @protocol_versions.first
    end

    # Removes all resource subscriptions held by +session_key+. Called by transports on session
    # teardown or idle reaping. Returns the number of distinct URIs that were touched.
    def remove_subscriber(session_key)
      @subscriptions_mutex.synchronize do
        touched = @resource_subscriptions.count { |_uri, keys| keys.include?(session_key) }
        @resource_subscriptions.each_value { |keys| keys.delete(session_key) }
        @resource_subscriptions.delete_if { |_uri, keys| keys.empty? }
        touched
      end
    end

    # @param mode [Symbol] one of FILTER_MODES
    # @raise [ArgumentError] on an unknown mode
    def filter_mode=(mode)
      mode = mode.to_sym
      unless FILTER_MODES.include?(mode)
        raise ArgumentError, "filter_mode must be one of #{FILTER_MODES.join(', ')}, got #{mode.inspect}"
      end

      @filter_mode = mode
    end

    # The request currently being served, when a transport supplied one.
    #
    # @return [Rack::Request, nil]
    def current_request
      current_request_context&.dig(:request)
    end

    # Register multiple tools at once
    # @param tools [Array<Tool>] Tools to register
    def register_tools(*tools)
      tools.each do |tool|
        register_tool(tool)
      end
    end

    # Register a tool with the server
    def register_tool(tool)
      @tools[tool.tool_name] = tool
      @logger.debug("Registered tool: #{tool.tool_name}")
      tool.server = self
      notify_tool_list_changed if @transport
      tool
    end

    # Removes a tool and notifies initialized clients.
    #
    # @param tool_name [String, Symbol] registered protocol name
    # @return [Boolean] whether a tool was removed
    def remove_tool(tool_name) # rubocop:disable Naming/PredicateMethod
      removed = @tools.delete(tool_name.to_s)
      notify_tool_list_changed if removed && @transport
      !removed.nil?
    end

    # Register multiple resources at once
    # @param resources [Array<Resource>] Resources to register
    def register_resources(*resources)
      resources.each do |resource|
        register_resource(resource)
      end
    end

    # Register a resource with the server
    def register_resource(resource)
      @resources << resource

      @logger.debug("Registered resource: #{resource.resource_name} (#{resource.uri})")
      resource.server = self
      # Notify subscribers about the list change
      notify_resource_list_changed if @transport

      resource
    end

    # Registers multiple prompt classes.
    #
    # @param prompts [Array<Class<FastMcp::Prompt>>]
    # @return [Array<Class<FastMcp::Prompt>>]
    def register_prompts(*prompts)
      prompts.each { |prompt| register_prompt(prompt) }
    end

    # Registers one prompt class.
    #
    # @param prompt [Class<FastMcp::Prompt>]
    # @return [Class<FastMcp::Prompt>]
    def register_prompt(prompt)
      @prompts[prompt.prompt_name] = prompt
      prompt.server = self
      @logger.debug("Registered prompt: #{prompt.prompt_name}")
      prompt
    end

    # Removes one prompt. Prompt list-change notifications are intentionally
    # unsupported while the prompts capability advertises listChanged: false.
    #
    # @param prompt_name [String, Symbol]
    # @return [Boolean] whether a prompt was removed
    def remove_prompt(prompt_name) # rubocop:disable Naming/PredicateMethod
      !@prompts.delete(prompt_name.to_s).nil?
    end

    def on_error_result(&block)
      @on_error_result = block
    end

    # Registers a formatter for the text payload of a failed tools/call.
    #
    # Agents recover far better from a machine-readable failure than from a prose string: a
    # formatter can emit, say, a JSON envelope carrying a category, whether the call is worth
    # retrying, and what to do instead. Without one, the historical "Error: <message>" text is
    # used and behaviour is unchanged.
    #
    # Configuring a formatter also changes how an unauthorized call is reported: instead of a
    # JSON-RPC -32602 response it becomes a tool error (`isError: true`), so a client handles one
    # failure shape rather than two.
    #
    # @yieldparam message [String] human-readable failure description
    # @yieldparam tool_name [String, nil] the tool that failed, when known
    # @yieldparam error [Exception, nil] the underlying exception, when there was one
    # @yieldreturn [String] text for the MCP content block
    # @return [void]
    #
    # @example
    #   server.error_formatter do |message:, tool_name:, error:|
    #     JSON.generate(error: true, tool: tool_name, message: message,
    #                   retriable: error.is_a?(Timeout::Error))
    #   end
    def error_formatter(&block)
      @error_formatter = block
    end

    # Remove a resource from the server
    def remove_resource(uri)
      resource = @resources.find { |r| r.uri == uri }

      if resource
        @resources.delete(resource)
        @logger.debug("Removed resource: #{resource.name} (#{uri})")

        # Notify subscribers about the list change
        notify_resource_list_changed if @transport

        true
      else
        false
      end
    end

    # Start the server using stdio transport
    def start
      @logger.transport = :stdio
      @logger.info("Starting MCP server: #{@name} v#{@version}")
      @logger.info("Available tools: #{@tools.keys.join(', ')}")
      @logger.info("Available resources: #{@resources.map(&:resource_name).join(', ')}")

      # Use STDIO transport by default
      @transport_klass = FastMcp::Transports::StdioTransport
      @transport = @transport_klass.new(self, logger: @logger)
      @transport.start
    end

    # Start the server as a Rack middleware
    def start_rack(app, options = {})
      @transport_klass = options.delete(:transport) || FastMcp::Transports::RackTransport
      transport_name = @transport_klass.name.split('::').last

      @logger.info("Starting MCP server with #{transport_name}: #{@name} v#{@version}")
      @logger.info("Available tools: #{@tools.keys.join(', ')}")
      @logger.info("Available resources: #{@resources.map(&:resource_name).join(', ')}")

      @transport = @transport_klass.new(app, self, options.merge(logger: @logger))
      @transport.start

      # Return the transport as middleware
      @transport
    end

    # Handle a JSON-RPC request and return the response as a JSON string
    def handle_json_request(request, headers: {})
      request_str = request.is_a?(String) ? request : JSON.generate(request)

      handle_request(request_str, headers: headers)
    end

    # Handle incoming JSON-RPC request
    def handle_request(json_str, headers: {}) # rubocop:disable Metrics/MethodLength, Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity
      begin
        request = JSON.parse(json_str)
      rescue JSON::ParserError, TypeError
        # §1.6.1: parse errors are -32700, not -32600.
        return send_error(-32_700, 'Parse error', nil)
      end

      @logger.debug("Received request: #{request.inspect}")

      # §1.6.2: the body must be a JSON object. Arrays get a batching-specific message since
      # batching was removed in 2025-06-18. Other non-objects (number, string, null) get a generic
      # message. No exception text is ever forwarded to the client.
      unless request.is_a?(Hash)
        msg = request.is_a?(Array) ? 'JSON-RPC batching is not supported' : 'Invalid Request'
        return send_error(-32_600, msg, nil)
      end

      method = request['method']
      id     = request['id']
      params = request['params'] || {}

      # §1.6.3: jsonrpc must be exactly "2.0".
      return send_error(-32_600, 'Invalid Request', id) unless request['jsonrpc'] == '2.0'

      # §1.6.4: id must be a String, Integer or absent. Boolean, Hash, Array → reject.
      unless id.nil? || id.is_a?(String) || id.is_a?(Integer)
        return send_error(-32_600, 'Invalid Request: id must be a string or integer', nil)
      end

      # §1.6.4: method must be a String when present.
      unless method.nil? || method.is_a?(String)
        return send_error(-32_600, 'Invalid Request: method must be a string', id)
      end

      # §1.6.5: notifications have a method but no id — never reply to them.
      # Accept known notification methods silently; drop unknown ones with a debug log.
      if id.nil? && !method.nil?
        case method
        when 'notifications/initialized'
          handle_initialized_notification
        when 'notifications/cancelled', 'notifications/roots/list_changed',
             'notifications/progress'
          nil # accepted silently
        else
          @logger.debug("Dropping unknown notification: #{method}")
        end
        return nil
      end

      # §1.6.6: client responses (result/error with no method) are accepted silently.
      return nil if method.nil?

      case method
      when 'ping'
        send_result({}, id)
      when 'initialize'
        handle_initialize(params, id)
      when 'tools/list'
        handle_tools_list(id)
      when 'tools/call'
        handle_tools_call(params, headers, id)
      when 'prompts/list'
        handle_prompts_list(id)
      when 'prompts/get'
        handle_prompts_get(params, id)
      when 'resources/list'
        handle_resources_list(id)
      when 'resources/templates/list'
        handle_resources_templates_list(id)
      when 'resources/read'
        handle_resources_read(params, id)
      when 'resources/subscribe'
        handle_resources_subscribe(params, id)
      when 'resources/unsubscribe'
        handle_resources_unsubscribe(params, id)
      else
        send_error(-32_601, "Method not found: #{method}", id)
      end
    rescue StandardError => e
      # §1.6.7: internal errors are -32603; the message is hidden by default.
      # Logged in full server-side, never forwarded: backtraces disclose absolute paths and
      # internal structure. Set expose_internal_errors: true on the server to debug locally.
      @logger.error("Error handling request: #{e.message}")
      @logger.error(e.backtrace.join("\n")) if e.backtrace
      send_error(-32_603, @expose_internal_errors ? "Internal error: #{e.message}" : 'Internal error', id)
    end

    # Notify subscribers about a resource update.
    # Delivers only to the sessions that subscribed (§1.3). Falls back to a broadcast
    # when no per-session delivery is available (stdio has a single session).
    def notify_resource_updated(uri)
      return unless @client_initialized

      session_keys = @subscriptions_mutex.synchronize do
        @resource_subscriptions[uri]&.to_a
      end
      return if session_keys.nil? || session_keys.empty?

      @logger.debug("Notifying #{session_keys.size} subscriber(s) about resource update: #{uri}")

      resource = @resources.find { |r| r.uri == uri }
      notification = {
        jsonrpc: '2.0',
        method: 'notifications/resources/updated',
        params: { uri: uri }
      }
      notification[:params][:name]     = resource.resource_name if resource
      notification[:params][:mimeType] = resource.mime_type if resource&.mime_type

      if @transport.respond_to?(:send_message_to)
        session_keys.each { |key| @transport.send_message_to(key, notification) }
      else
        @transport.send_message(notification)
      end
    end

    def read_resource(uri)
      @resources.find { |r| r.match(uri) }
    end

    # Runs server dispatch with request-scoped response routing.
    #
    # Nested contexts are restored in ensure, and contexts are isolated by
    # server instance within the current thread.
    #
    # @param transport [#send_message] transport for responses in this request
    # @param metadata [Hash] optional transport/session context
    # @yieldreturn [Object] caller block result
    # @return [Object] caller block result
    def with_request_context(transport:, **metadata)
      contexts = Thread.current[:fast_mcp_request_contexts] ||= {}.compare_by_identity
      previous = contexts[self]
      contexts[self] = metadata.merge(transport: transport)
      yield
    ensure
      if contexts
        previous ? contexts[self] = previous : contexts.delete(self)
        Thread.current[:fast_mcp_request_contexts] = nil if contexts.empty?
      end
    end

    # Returns the current request context for this server/thread.
    #
    # @return [Hash, nil]
    def current_request_context
      Thread.current[:fast_mcp_request_contexts]&.[](self)
    end

    private

    def handle_initialize(params, id)
      # Store client capabilities for later use
      @client_capabilities = params['capabilities'] || {}
      client_info = params['clientInfo'] || {}

      # Negotiate the protocol version (§1.1): echo a supported value, else answer the newest.
      @negotiated_protocol_version = negotiate_protocol_version(params['protocolVersion'])

      # Log client information
      @logger.info("Client connected: #{client_info['name']} v#{client_info['version']}")
      @logger.info("Protocol version negotiated: #{@negotiated_protocol_version} " \
                   "(requested: #{params['protocolVersion'].inspect})")

      response = {
        protocolVersion: @negotiated_protocol_version,
        capabilities: @capabilities,
        serverInfo: {
          name: @name,
          version: @version
        }
      }

      send_result(response, id)
    end

    # Handle a resource read
    def handle_resources_read(params, id)
      uri = params['uri']

      return send_error(-32_602, 'Invalid params: missing resource URI', id) unless uri

      @logger.debug("Looking for resource with URI: #{uri}")

      begin
        # Filtered, so a resource this request cannot see is indistinguishable from one that does
        # not exist — otherwise knowing a URI would be enough to bypass the filter.
        resource = visible_resource(uri, current_request)
        return send_error(-32_602, "Resource not found: #{uri}", id) unless resource

        @logger.debug("Found resource: #{resource.resource_name}, templated: #{resource.templated?}")

        base_content = { uri: uri }
        base_content[:mimeType] = resource.mime_type if resource.mime_type
        resource_instance = resource.initialize_from_uri(uri)
        @logger.debug("Resource instance params: #{resource_instance.params.inspect}")

        result = if resource_instance.binary?
                   {
                     contents: [base_content.merge(blob: Base64.strict_encode64(resource_instance.content))]
                   }
                 else
                   {
                     contents: [base_content.merge(text: resource_instance.content)]
                   }
                 end

        # # rescue StandardError => e
        # @logger.error("Error reading resource: #{e.message}")
        # @logger.error(e.backtrace.join("\n"))
        send_result(result, id)
      end
    end

    def handle_initialized_notification
      # The client is now ready for normal operation
      # No response needed for notifications
      @client_initialized = true
      @logger.info('Client initialized, beginning normal operation')

      nil
    end

    # Handle prompts/list request.
    def handle_prompts_list(id)
      send_result({ prompts: visible_prompts(current_request).map(&:metadata) }, id)
    end

    # Handle prompts/get request.
    def handle_prompts_get(params, id)
      name = params['name']
      return send_error(-32_602, 'Invalid params: missing prompt name', id) if name.nil? || name.empty?

      prompt = @prompts[name]
      return send_error(-32_602, "Prompt not found: #{name}", id) unless prompt

      # A filtered prompt is not fetchable by name either, or prompts/list would be decoration.
      unless prompt_visible?(prompt, current_request)
        return send_error(-32_602, "Prompt not found: #{name}", id) if @filter_mode == :hide

        return send_unauthorized_result(name, id)
      end

      arguments = params['arguments'] || {}
      missing = prompt.arguments.filter_map do |definition|
        definition[:name] if definition[:required] && !arguments.key?(definition[:name])
      end
      if missing.any?
        return send_error(
          -32_602,
          "Invalid params: missing required prompt arguments: #{missing.join(', ')}",
          id
        )
      end

      messages = prompt.new.messages(**symbolize_keys(arguments))
      send_result({ description: prompt.description.to_s, messages: messages }, id)
    end

    # Handle tools/list request
    def handle_tools_list(id)
      tools_list = visible_tools(current_request).map do |tool|
        tool_info = {
          name: tool.tool_name,
          description: tool.description || '',
          inputSchema: tool.input_schema_to_json || { type: 'object', properties: {}, required: [] }
        }
        output_schema = tool.output_schema_to_json
        tool_info[:outputSchema] = output_schema if output_schema

        # Add annotations if they exist
        annotations = tool.annotations
        unless annotations.empty?
          # Convert snake_case keys to camelCase for MCP protocol
          camel_case_annotations = {}
          annotations.each do |key, value|
            camel_key = key.to_s.gsub(/_([a-z])/) { ::Regexp.last_match(1).upcase }.to_sym
            camel_case_annotations[camel_key] = value
          end
          tool_info[:annotations] = camel_case_annotations
        end

        tool_info
      end

      send_result({ tools: tools_list }, id)
    end

    # Handle tools/call request
    def handle_tools_call(params, headers, id)
      tool_name = params['name']
      arguments = params['arguments'] || {}

      return send_error(-32_602, 'Invalid params: missing tool name', id) unless tool_name

      tool = @tools[tool_name]
      return send_error(-32_602, "Tool not found: #{tool_name}", id) unless tool

      # A tool filtered out of this request is not callable either, otherwise tools/list would be
      # decoration rather than a boundary.
      unless tool_visible?(tool, current_request)
        return send_error(-32_602, "Tool not found: #{tool_name}", id) if @filter_mode == :hide

        return send_unauthorized_result(tool_name, id)
      end

      begin
        # Convert string keys to symbols for Ruby
        symbolized_args = symbolize_keys(arguments)

        tool_instance = tool.new(headers: headers)
        authorized = tool_instance.authorized?(**symbolized_args)

        return send_unauthorized_result(tool_name, id) unless authorized

        result, metadata = tool_instance.call_with_schema_validation!(**symbolized_args)

        # Format and send the result
        send_formatted_result(result, id, metadata, tool: tool)
      rescue FastMcp::Tool::InvalidArgumentsError => e
        @logger.error("Invalid arguments for tool #{tool_name}: #{e.message}")
        send_error_result(e.message, id, tool_name: tool_name, error: e)
      rescue StandardError => e
        # The backtrace is logged, never sent: it discloses absolute paths and internal structure
        # to whoever is driving the client.
        @logger.error("Error calling tool #{tool_name}: #{e.message}")
        @logger.error(e.backtrace.join("\n")) if e.backtrace
        send_error_result(e.message, id, tool_name: tool_name, error: e)
      end
    end

    # Reports a refused tool call.
    #
    # Without an +error_formatter+ this keeps the historical JSON-RPC -32602 response. With one
    # configured, the refusal is reported as a tool error instead, so a client sees the same
    # shape for "not allowed" as for any other failure.
    #
    # @param tool_name [String]
    # @param id [Integer, String]
    # @return [void]
    def send_unauthorized_result(tool_name, id)
      @logger.error("Unauthorized tool call: #{tool_name}")
      return send_error(-32_602, 'Unauthorized', id) unless @error_formatter

      send_error_result('Unauthorized', id, tool_name: tool_name, error: UnauthorizedError.new('Unauthorized'))
    end

    # Format and send successful result
    def send_formatted_result(result, id, metadata, tool: nil)
      # Check if the result is already in the expected format
      if result.is_a?(Hash) && result.key?(:content)
        send_result(result, id, metadata: metadata)
      elsif tool&.output_schema_to_json && result.is_a?(Hash)
        structured_content = JSON.parse(JSON.generate(result))
        formatted_result = {
          content: [{ type: 'text', text: JSON.generate(structured_content) }],
          structuredContent: structured_content,
          isError: false
        }
        send_result(formatted_result, id, metadata: metadata)
      else
        # Format the result according to the MCP specification
        formatted_result = {
          content: [{ type: 'text', text: text_content_for(result) }],
          isError: false
        }

        send_result(formatted_result, id, metadata: metadata)
      end
    end

    # Renders a tool result as MCP text content.
    #
    # Hash and Array results are JSON-encoded. `to_s` would emit Ruby inspect syntax
    # (`{name: "value"}`), which is not valid JSON and cannot be parsed by a client, so a tool
    # returning structured data without declaring an `output_schema` used to be unusable.
    #
    # @param result [Object] value returned by the tool
    # @return [String] text suitable for an MCP content block
    def text_content_for(result)
      case result
      when String then result
      when Hash, Array then JSON.generate(result)
      else result.to_s
      end
    end

    # Format and send error result
    #
    # @param message [String] human-readable failure description
    # @param id [Integer, String] JSON-RPC request id
    # @param tool_name [String, nil] tool that failed, when known
    # @param error [Exception, nil] the underlying exception, when there was one
    # @return [void]
    def send_error_result(message, id, tool_name: nil, error: nil)
      @on_error_result&.call(message)

      # Format error according to the MCP specification
      error_result = {
        content: [{ type: 'text', text: error_text_for(message, tool_name: tool_name, error: error) }],
        isError: true
      }

      send_result(error_result, id)
    end

    # Builds the text payload of a failed tools/call, delegating to +error_formatter+ when one is
    # configured. Defaults to the historical "Error: <message>" string.
    #
    # A formatter is application code running on an error path, so a fault in it must not escalate
    # into a second, worse failure: it is contained here and the safe default is used instead.
    #
    # @return [String]
    def error_text_for(message, tool_name: nil, error: nil)
      return "Error: #{message}" unless @error_formatter

      begin
        @error_formatter.call(message: message, tool_name: tool_name, error: error).to_s
      rescue StandardError => e
        @logger.error("error_formatter raised #{e.class}: #{e.message}; falling back to default text")
        @logger.error(e.backtrace.join("\n")) if e.backtrace
        "Error: #{message}"
      end
    end

    # Handle resources/list request
    def handle_resources_list(id)
      resources_list = visible_resources(current_request).select(&:non_templated?).map(&:metadata)

      send_result({ resources: resources_list }, id)
    end

    # Handle resources/templates/list request
    def handle_resources_templates_list(id)
      # Collect templated resources
      templated_resources_list = visible_resources(current_request).select(&:templated?).map(&:metadata)

      send_result({ resourceTemplates: templated_resources_list }, id)
    end

    # Handle resources/subscribe request (§1.3: keyed by session, not request id)
    def handle_resources_subscribe(params, id)
      return unless @client_initialized

      uri = params['uri']
      unless uri
        send_error(-32_602, 'Invalid params: missing resource URI', id)
        return
      end

      resource = visible_resource(uri, current_request)
      return send_error(-32_602, "Resource not found: #{uri}", id) unless resource

      session_key = current_session_key
      @subscriptions_mutex.synchronize { @resource_subscriptions[uri].add(session_key) }

      send_result({ subscribed: true }, id)
    end

    # Handle resources/unsubscribe request (§1.3: keyed by session, not request id)
    def handle_resources_unsubscribe(params, id)
      return unless @client_initialized

      uri = params['uri']
      unless uri
        send_error(-32_602, 'Invalid params: missing resource URI', id)
        return
      end

      session_key = current_session_key
      @subscriptions_mutex.synchronize do
        @resource_subscriptions[uri].delete(session_key)
        @resource_subscriptions.delete(uri) if @resource_subscriptions[uri].empty?
      end

      send_result({ unsubscribed: true }, id)
    end

    # Notify clients about resource list changes
    def notify_resource_list_changed
      return unless @client_initialized

      notification = {
        jsonrpc: '2.0',
        method: 'notifications/resources/listChanged',
        params: {}
      }

      @transport.send_message(notification)
    end

    # Notify clients that tools/list should be refreshed.
    def notify_tool_list_changed
      return unless @client_initialized

      @transport.send_message(
        jsonrpc: '2.0',
        method: 'notifications/tools/list_changed',
        params: {}
      )
    end

    # Send a JSON-RPC result response
    def send_result(result, id, metadata: {})
      result[:_meta] = metadata if metadata.is_a?(Hash) && !metadata.empty?

      response = {
        jsonrpc: '2.0',
        id: id,
        result: result
      }

      @logger.info("Sending result: #{response.inspect}")
      send_response(response)
    end

    # Send a JSON-RPC error response
    def send_error(code, message, id = nil)
      response = {
        jsonrpc: '2.0',
        error: {
          code: code,
          message: message
        },
        id: id
      }

      send_response(response)
    end

    # Send a JSON-RPC response
    def send_response(response)
      response_transport = current_request_context&.fetch(:transport, nil) || @transport
      if response_transport
        @logger.debug("Sending response: #{response.inspect}")
        response_transport.send_message(response)
      else
        @logger.warn("No transport available to send response: #{response.inspect}")
        @logger.warn("Transport: #{@transport.inspect}, transport_klass: #{@transport_klass.inspect}")
      end
    end

    # Helper method to convert string keys to symbols
    def symbolize_keys(hash)
      return hash unless hash.is_a?(Hash)

      hash.each_with_object({}) do |(key, value), result|
        new_key = key.is_a?(String) ? key.to_sym : key
        new_value = value.is_a?(Hash) ? symbolize_keys(value) : value
        result[new_key] = new_value
      end
    end

    # Derives a stable per-session key from the current request context (§1.3).
    # Falls back to :stdio for the stdio transport (one session).
    def current_session_key
      ctx = current_request_context
      ctx&.dig(:session_id) || ctx&.dig(:client_id) || :stdio
    end

    # Validates a candidate protocol_versions list and returns it stored newest-first.
    # Raises ArgumentError for an empty list, non-YYYY-MM-DD strings, or modern (>= 2026-07-28)
    # versions (those have no handshake; advertising them would be wrong).
    def validate_protocol_versions!(versions)
      versions = Array(versions)
      raise ArgumentError, 'protocol_versions must not be empty' if versions.empty?

      versions.each do |v|
        raise ArgumentError, "protocol_versions: #{v.inspect} is not a YYYY-MM-DD string" \
          unless v.is_a?(String) && v.match?(/\A\d{4}-\d{2}-\d{2}\z/)
        if v >= '2026-07-28'
          raise ArgumentError, "protocol_versions: #{v} is a modern-era version and cannot be " \
                               'negotiated via initialize; remove it from the list'
        end
      end

      versions.sort.reverse
    end
  end
end
