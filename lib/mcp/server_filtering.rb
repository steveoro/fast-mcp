# frozen_string_literal: true

module FastMcp
  # Module for handling server filtering functionality
  module ServerFiltering
    # Add filter for tools
    def filter_tools(&block)
      @tool_filters << block if block_given?
    end

    # Add filter for resources
    def filter_resources(&block)
      @resource_filters << block if block_given?
    end

    # Check if filters are configured
    def contains_filters?
      @tool_filters.any? || @resource_filters.any?
    end

    # Tools this request is allowed to see, filtered in place.
    #
    # In place, rather than by cloning the server, because +register_tool+ assigns
    # +tool.server = self+ — state on the tool *class*. A filtered copy therefore reassigns that
    # pointer globally, and since request contexts are keyed by server identity, a tool would end
    # up reading a different request's context, or none. See #create_filtered_copy.
    #
    # @param request [Rack::Request, nil] nil means no request scope, so nothing is filtered
    # @return [Array<Class>]
    def visible_tools(request)
      return @tools.values if request.nil? || @tool_filters.empty?

      apply_tool_filters(request)
    end

    # Resources this request is allowed to see. Counterpart of #visible_tools.
    #
    # @param request [Rack::Request, nil]
    # @return [Array]
    def visible_resources(request)
      return @resources if request.nil? || @resource_filters.empty?

      apply_resource_filters(request)
    end

    # @param tool [Class]
    # @param request [Rack::Request, nil]
    # @return [Boolean] whether this request may call the tool
    def tool_visible?(tool, request)
      visible_tools(request).include?(tool)
    end

    # Create a filtered copy for a specific request.
    #
    # @deprecated Unsafe to combine with per-request contexts: registering the tools on the copy
    #   reassigns +tool.server+ for every other request too. Prefer #visible_tools, which the
    #   server now uses to answer tools/list and tools/call. Retained for callers that relied on
    #   receiving a separate Server instance.
    def create_filtered_copy(request)
      filtered_server = self.class.new(
        name: @name,
        version: @version,
        logger: @logger,
        capabilities: @capabilities
      )

      # Copy transport settings
      filtered_server.transport_klass = @transport_klass

      # Apply filters and register items
      register_filtered_tools(filtered_server, request)
      register_filtered_resources(filtered_server, request)
      filtered_server.register_prompts(*@prompts.values)

      filtered_server
    end

    private

    # Apply tool filters and register filtered tools
    def register_filtered_tools(filtered_server, request)
      filtered_tools = apply_tool_filters(request)

      # Register filtered tools
      filtered_tools.each do |tool|
        filtered_server.register_tool(tool)
      end
    end

    # Apply resource filters and register filtered resources
    def register_filtered_resources(filtered_server, request)
      filtered_resources = apply_resource_filters(request)

      # Register filtered resources
      filtered_resources.each do |resource|
        filtered_server.register_resource(resource)
      end
    end

    # Apply all tool filters to the tools collection
    def apply_tool_filters(request)
      filtered_tools = @tools.values
      @tool_filters.each do |filter|
        filtered_tools = filter.call(request, filtered_tools)
      end
      filtered_tools
    end

    # Apply all resource filters to the resources collection
    def apply_resource_filters(request)
      filtered_resources = @resources
      @resource_filters.each do |filter|
        filtered_resources = filter.call(request, filtered_resources)
      end
      filtered_resources
    end
  end
end
