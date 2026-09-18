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
    # +tool.server = self+ — state on the tool *class*. A filtered copy would therefore reassign
    # that pointer globally and break per-request context isolation.
    #
    # @param request [Rack::Request, nil] nil means no request scope, so nothing is filtered
    # @return [Array<Class>]
    def visible_tools(request)
      if request.nil?
        warn_filters_inactive if @tool_filters.any?
        return @tools.values
      end
      return @tools.values if @tool_filters.empty?

      apply_tool_filters(request)
    end

    # Resources this request is allowed to see. Counterpart of #visible_tools.
    #
    # @param request [Rack::Request, nil]
    # @return [Array]
    def visible_resources(request)
      if request.nil?
        warn_filters_inactive if @resource_filters.any?
        return @resources
      end
      return @resources if @resource_filters.empty?

      apply_resource_filters(request)
    end

    # Resource matching the URI that this request is allowed to see.
    #
    # Used instead of #read_resource wherever a request is being served, so that a filtered-out
    # resource cannot be reached by guessing or remembering its URI.
    #
    # @param uri [String]
    # @param request [Rack::Request, nil]
    # @return [Object, nil]
    def visible_resource(uri, request)
      visible_resources(request).find { |resource| resource.match(uri) }
    end

    # @param tool [Class]
    # @param request [Rack::Request, nil]
    # @return [Boolean] whether this request may call the tool
    def tool_visible?(tool, request)
      visible_tools(request).include?(tool)
    end

    private

    # Filters need a request to filter against. A transport that never supplies one turns every
    # filter into a no-op, which fails open and looks like everything is working — so say so,
    # once, rather than silently serving the unfiltered catalogue.
    def warn_filters_inactive
      return if @warned_filters_inactive

      @warned_filters_inactive = true
      logger&.warn(
        'Filters are configured but no request is in scope, so nothing is being filtered. ' \
        'Transports must pass `request:` to with_request_context; FastMcp::Transports::RackTransport does.'
      )
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
