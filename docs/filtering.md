# Dynamic Tool and Resource Filtering

Fast MCP provides a powerful filtering system that allows you to dynamically control which tools and resources are available based on request context. This is useful for implementing:

- Permission-based access control
- API versioning
- Feature flags
- Multi-tenancy
- Environment-specific functionality
- Rate limiting

## Table of Contents

- [Overview](#overview)
- [Basic Usage](#basic-usage)
- [Tool Tagging](#tool-tagging)
- [Filter Functions](#filter-functions)
- [Advanced Usage](#advanced-usage)
- [Thread Safety](#thread-safety)
- [Examples](#examples)
- [Best Practices](#best-practices)

## Overview

The filtering system works by:

1. Defining filters on the server that examine request context
2. Creating request-scoped server instances with filtered tools/resources
3. Using these filtered servers to handle specific requests

This approach is completely thread-safe as each request gets its own server instance with the appropriate tools and resources.

## Basic Usage

### Adding a Simple Filter

```ruby
FastMcp.mount_in_rails(app) do |server|
  # Register all tools
  server.register_tools(AdminTool, UserTool, PublicTool)
  
  # Add a filter based on request parameters
  server.filter_tools do |request, tools|
    role = request.params['role']
    
    case role
    when 'admin'
      tools # Admin sees all tools
    when 'user'
      tools.reject { |t| t.tags.include?(:admin) }
    else
      tools.select { |t| t.tags.include?(:public) }
    end
  end
end
```

### Filtering Resources

```ruby
server.filter_resources do |request, resources|
  tenant_id = request.headers['X-Tenant-ID']
  
  # Only show resources for the current tenant
  resources.select { |r| r.tenant_id == tenant_id }
end
```

## Tool Tagging

Tools can be tagged for easier filtering:

```ruby
class DangerousTool < FastMcp::Tool
  tool_name 'delete_all'
  description 'Delete all data'
  tags :admin, :dangerous, :write
  
  def call
    # Dangerous operation
  end
end

class ReadOnlyTool < FastMcp::Tool
  tool_name 'list_users'
  description 'List all users'
  tags :read, :safe
  
  def call
    # Safe read operation
  end
end
```

Tools can also have metadata:

```ruby
class ReportingTool < FastMcp::Tool
  tool_name 'generate_report'
  description 'Generate a report'
  
  metadata :category, 'reporting'
  metadata :cpu_intensive, true
  metadata :requires_license, 'enterprise'
  
  def call
    # Generate report
  end
end
```

## Filter Functions

Filter functions receive two parameters:
- `request`: A Rack::Request object with access to params, headers, etc.
- `tools` or `resources`: An array of available tools/resources

They should return a filtered array.

### Multiple Filters

Filters are applied in sequence:

```ruby
# First filter: Remove dangerous tools in production
server.filter_tools do |request, tools|
  if Rails.env.production?
    tools.reject { |t| t.tags.include?(:dangerous) }
  else
    tools
  end
end

# Second filter: Apply role-based access
server.filter_tools do |request, tools|
  role = request.params['role']
  role == 'admin' ? tools : tools.reject { |t| t.tags.include?(:admin) }
end
```

### Header-Based Filtering

```ruby
server.filter_tools do |request, tools|
  api_version = request.env['HTTP_X_API_VERSION']
  
  case api_version
  when 'v2'
    tools # All tools available in v2
  when 'v1'
    tools.reject { |t| t.tags.include?(:v2_only) }
  else
    [] # No tools for unversioned requests
  end
end
```

## Advanced Usage

### Custom Server in Environment

For advanced use cases, you can provide a custom server instance via the environment:

```ruby
# In a middleware or controller
env['fast_mcp.server'] = custom_filtered_server
```

This takes precedence over any configured filters.

### What Filtering Covers

Filters apply to every request path, so a filtered item is unreachable rather than merely
unlisted:

| Path | Behaviour when filtered out |
|---|---|
| `tools/list` | Absent |
| `tools/call` | Refused — see [Filter Modes](#filter-modes) |
| `resources/list`, `resources/templates/list` | Absent |
| `resources/read`, `resources/subscribe` | Reported as not found |

A filtered resource answers exactly as an unknown one does, so knowing or guessing a URI reveals
nothing.

### Filter Modes

`Server#filter_mode` chooses how a refused tool call reads:

```ruby
server.filter_mode = :deny # default is :hide
```

- `:hide` reports the tool as unknown, giving nothing away about what exists.
- `:deny` reports it as a refusal. Friendlier to an agent, which can then explain the situation
  instead of assuming it mistyped a tool name. When an
  [error formatter](tools.md#error-formatting) is configured, the refusal is delivered through it
  as a structured payload.

### Resolving Visibility Directly

`visible_tools(request)`, `visible_resources(request)` and `tool_visible?(tool, request)` answer
what a given request may see, should you need it outside the normal dispatch path. Pass `nil` for
the request to skip filtering entirely.

### Combining with Authentication

```ruby
server.filter_tools do |request, tools|
  # Get user from your authentication system
  user = authenticate_request(request)
  
  return [] unless user # No tools for unauthenticated requests
  
  # Filter based on user permissions
  tools.select { |t| user.can_access_tool?(t) }
end
```

## Thread Safety

Filters are applied **in place**, against the request carried in the server's per-request
context. Nothing is cloned and no shared state is mutated, so concurrent requests with different
filters do not interfere.

Earlier versions built a filtered copy of the server for each request. That looked safer but was
not: registering the tools on a copy assigns `tool.server = self`, which is state on the tool
*class*, so one request's copy silently repointed every other request's tools at it. Because
request contexts are keyed by server identity, a concurrent tool reading
`self.class.server.current_request_context` could get another request's context, or none.

`create_filtered_copy` still exists for callers that genuinely want a separate `Server` instance,
but it carries that caveat and is no longer used to serve requests. Avoid combining it with
per-request contexts.

## Custom Transports

Filters are evaluated against the request in the server's per-request context, so a transport
must supply one:

```ruby
server.with_request_context(transport: self, request: request) do
  server.handle_request(body, headers: headers)
end
```

`FastMcp::Transports::RackTransport` does this already. A custom transport that omits `request:`
will find that **every filter silently becomes a no-op** — the catalogue is served unfiltered and
nothing appears to be wrong. The server logs a warning once when it notices filters configured
with no request in scope, but the warning is a safety net, not a substitute for passing it.

A stdio transport has no request and legitimately cannot filter; configure filters only on
transports that can supply one.

## Examples

### Permission-Based Access Control

```ruby
class AdminTool < FastMcp::Tool
  tags :admin
  description "Administrative functions"
  
  def call
    "Admin action performed"
  end
end

class UserTool < FastMcp::Tool
  tags :user
  description "User functions"
  
  def call
    "User action performed"
  end
end

server.filter_tools do |request, tools|
  user_role = request.headers['X-User-Role']
  
  case user_role
  when 'admin'
    tools
  when 'user'
    tools.reject { |t| t.tags.include?(:admin) }
  else
    []
  end
end
```

### Feature Flags

```ruby
server.filter_tools do |request, tools|
  user_id = request.headers['X-User-ID']
  enabled_features = FeatureFlags.for_user(user_id)
  
  tools.reject do |tool|
    tool.metadata(:feature_flag) && 
    !enabled_features.include?(tool.metadata(:feature_flag))
  end
end
```

### Rate Limiting

```ruby
server.filter_tools do |request, tools|
  client_ip = request.ip
  
  if RateLimiter.exceeded?(client_ip, :expensive_operations)
    tools.reject { |t| t.metadata(:expensive) }
  else
    tools
  end
end
```

## Best Practices

1. **Keep Filters Fast**: Filters run on every request, so keep them efficient
2. **Use Tags Wisely**: Create a consistent tagging system across your tools
3. **Cache When Possible**: The built-in caching helps, but consider caching expensive checks
4. **Fail Secure**: When in doubt, exclude tools rather than include them
5. **Log Filter Actions**: Consider logging when tools are filtered for debugging
6. **Test Thoroughly**: Write tests for your filter logic to ensure security

## Migration from Custom Solutions

If you have existing middleware that modifies tool availability, you can migrate to the filtering system:

```ruby
# Before: Custom middleware
class ToolFilterMiddleware
  def call(env)
    # Complex logic to modify server tools
  end
end

# After: Using filter_tools
server.filter_tools do |request, tools|
  # Same logic, but cleaner and thread-safe
end
```

The filtering system handles all the complexity of creating request-scoped servers and ensuring thread safety. 