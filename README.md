# Fast MCP 🚀

<div align="center">
  <h3>Connect AI models to your Ruby applications with ease</h3>
  <p>No complex protocols, no integration headaches, no compatibility issues – just beautiful, expressive Ruby code.</p>
</div>

<p align="center">
  <a href="https://github.com/steveoro/fast-mcp/releases"><img src="https://img.shields.io/github/v/release/steveoro/fast-mcp" alt="GitHub Release" /></a>
  <a href="https://github.com/steveoro/fast-mcp/actions/workflows/ci.yml"><img src="https://github.com/steveoro/fast-mcp/actions/workflows/ci.yml/badge.svg" alt="CI Status" /></a>
  <a href="https://opensource.org/licenses/MIT"><img src="https://img.shields.io/badge/License-MIT-yellow.svg" alt="License: MIT" /></a>
  <a href="code_of_conduct.md"><img src="https://img.shields.io/badge/Contributor%20Covenant-2.1-4baaaa.svg" alt="Contributor Covenant" /></a>
  <a href="https://discord.gg/9HHfAtY3HF"><img src = "https://dcbadge.limes.pink/api/server/https://discord.gg/9HHfAtY3HF?style=flat" alt="Discord invite link" /></a>
</p>

## 🌟 Interface your Servers with LLMs in minutes

AI models are powerful, but they need to interact with your applications to be truly useful. Traditional approaches mean wrestling with:

- 🔄 Complex communication protocols and custom JSON formats
- 🔌 Integration challenges with different model providers
- 🧩 Compatibility issues between your app and AI tools
- 🧠 Managing the state between AI interactions and your data

Fast MCP solves all these problems by providing a clean, Ruby-focused implementation of the [Model Context Protocol](https://github.com/modelcontextprotocol), making AI integration a joy, not a chore.

## Installation

This maintained fork (`steveoro/fast-mcp`, forked from `yjacquin/fast-mcp`) is distributed from GitHub rather than RubyGems:

```ruby
gem 'fast-mcp',
    git: 'https://github.com/steveoro/fast-mcp.git',
    tag: 'v1.8.0'
```

The gem name, `require 'fast_mcp'`, and the `FastMcp` module remain compatible
with the original project.

### Protocol version support

`FastMcp::Server` advertises the following handshake-era versions (newest first):

```
2025-11-25  2025-06-18  2025-03-26  2024-11-05
```

`initialize` echoes a supported requested version; anything else (garbage, `nil`, or a
modern `2026-07-28`+ value) gets the newest version (`2025-11-25`). The modern era
(`2026-07-28`, no handshake) is **not served yet** — a `server/discover` probe
returns `-32601`, and SDK clients in `auto` mode fall back to the legacy path
automatically.

To cap the list (e.g. to two versions):

```ruby
FastMcp::Server.new(name: 'myapp', version: '1.0',
                    protocol_versions: %w[2025-03-26 2024-11-05])
```

## ✨ Features

- 🛠️ **Tools API** - Let AI models call your Ruby functions securely, with in-depth argument validation through [Dry-Schema](https://github.com/dry-rb/dry-schema).
- 📚 **Resources API** - Share data between your app and AI models
- 💬 **Prompts API** - Publish reusable, argument-aware workflow prompts
- 🔄 **Multiple Transports** - Choose from STDIO, HTTP, or SSE based on your needs
- 🧩 **Framework Integration** - Works seamlessly with Rails, Sinatra or any Rack app.
- 🔒 **Authentication Support** - Secure your AI-powered endpoints with ease
- 🚀 **Real-time Updates** - Subscribe to changes for interactive applications
- 🎯 **Dynamic Filtering** - Control tool/resource access based on request context (permissions, API versions, etc.)

### Prompt example

```ruby
class RecallPrompt < FastMcp::Prompt
  prompt_name 'recall'
  description 'Recall project knowledge'
  argument :topic, description: 'Subject to recall', required: true

  def messages(topic:)
    [{ role: 'user', content: { type: 'text', text: "Recall #{topic}" } }]
  end
end

server.register_prompt(RecallPrompt)
```

Clients discover prompts with `prompts/list` and render one with
`prompts/get`.

## 💎 What Makes FastMCP Great

```ruby
# Define tools for AI models to use
server = FastMcp::Server.new(name: 'popular-users', version: '1.0.0')

# Define a tool by inheriting from FastMcp::Tool
class CreateUserTool < FastMcp::Tool
  description "Create a user"
    # These arguments will generate the needed JSON to be presented to the MCP Client
    # And they will be validated at run time.
    # The validation is based off Dry-Schema, with the addition of the description.
  arguments do
    required(:first_name).filled(:string).description("First name of the user")
    optional(:age).filled(:integer).description("Age of the user")
    required(:address).description("The shipping address").hash do
      required(:street).filled(:string).description("Street address")
      optional(:city).filled(:string).description("City name")
      optional(:zipcode).maybe(:string).description("Postal code")
    end
  end

  def call(first_name:, age: nil, address: {})
    User.create!(first_name:, age:, address:)
  end
end

# Register the tool with the server
server.register_tool(CreateUserTool)

# Share data resources with AI models by inheriting from FastMcp::Resource
class PopularUsers < FastMcp::Resource
  uri "myapp:///users/popular"
  resource_name "Popular Users"
  mime_type "application/json"

  def content
    JSON.generate(User.popular.limit(5).as_json)
  end
end

class User < FastMcp::Resource
  uri "myapp:///users/{id}" # This is a resource template
  resource_name "user"
  mime_type "application/json"

  def content
    id = params[:id] # params are computed from the uri pattern

    JSON.generate(User.find(id).as_json)
  end
end

# Register the resource with the server
server.register_resources(PopularUsers, User)

# Accessing the resource through the server
server.read_resource(PopularUsers.uri)

# Notify the resource content has been updated to clients
server.notify_resource_updated(PopularUsers.variabilized_uri)

# Notifiy the content of a resource from a template has been updated to clients
server.notify_resource_updated(User.variabilized_uri(id: 1))
```

### 🎯 Dynamic Tool Filtering

Control which tools and resources are available based on request context:

```ruby
# Tag your tools for easy filtering
class AdminTool < FastMcp::Tool
  tags :admin, :dangerous
  description "Perform admin operations"

  def call
    # Admin only functionality
  end
end

# Filter tools based on user permissions
server.filter_tools do |request, tools|
  user_role = request.params['role']

  case user_role
  when 'admin'
    tools # Admins see all tools
  when 'user'
    tools.reject { |t| t.tags.include?(:admin) }
  else
    tools.select { |t| t.tags.include?(:public) }
  end
end
```

Filters are evaluated in place and enforced on tool calls and every resource
discovery/read path. Set `server.filter_mode = :deny` for an actionable refusal
instead of the default hidden/not-found behavior. See
[Dynamic Filtering](docs/filtering.md).

### 🚂 Fast Ruby on Rails implementation

```shell
bin/rails generate fast_mcp:install
```

This will add a configurable `fast_mcp.rb` initializer

```ruby
require 'fast_mcp'

FastMcp.mount_in_rails(
  Rails.application,
  name: Rails.application.class.module_parent_name.underscore.dasherize,
  version: '1.0.0',
  path_prefix: '/mcp', # This is the default path prefix
  messages_route: 'messages', # This is the default route for the messages endpoint
  sse_route: 'sse', # This is the default route for the SSE endpoint
  # Add allowed origins below, it defaults to Rails.application.config.hosts
  # allowed_origins: ['localhost', '127.0.0.1', 'example.com', /.*\.example\.com/],
  # localhost_only: true, # Omit allowed_ips to enforce loopback defaults
  # localhost_only: false, # Remote clients allowed when allowed_ips is omitted
  # allowed_ips: ['127.0.0.1', '192.168.0.0/16'], # Explicit lists are always enforced
  # authenticate: true,       # Uncomment to enable authentication
  # auth_token: 'your-token' # Required if authenticate: true
) do |server|
  Rails.application.config.after_initialize do
    # FastMcp will automatically discover and register:
    # - All classes that inherit from ApplicationTool (which uses ActionTool::Base)
    # - All classes that inherit from ApplicationResource (which uses ActionResource::Base)
    server.register_tools(*ApplicationTool.descendants)
    server.register_resources(*ApplicationResource.descendants)
    # alternatively, you can register tools and resources manually:
    # server.register_tool(MyTool)
    # server.register_resource(MyResource)
  end
end
```

The install script will also:

- add app/resources folder
- add app/tools folder
- add app/tools/sample_tool.rb
- add app/resources/sample_resource.rb
- add ApplicationTool to inherit from
- add ApplicationResource to inherit from as well

#### Rails-friendly class naming conventions

For Rails applications, FastMCP provides Rails-style class names to better fit with Rails conventions:

- `ActionTool::Base` - An alias for `FastMcp::Tool`
- `ActionResource::Base` - An alias for `FastMcp::Resource`

These are automatically set up in Rails applications. You can use either naming convention in your code:

```ruby
# Using Rails-style naming:
class MyTool < ActionTool::Base
  description "My awesome tool"

  arguments do
    required(:input).filled(:string)
  end

  def call(input:)
    # Your implementation
  end
end

# Using standard FastMcp naming:
class AnotherTool < FastMcp::Tool
  # Both styles work interchangeably in Rails apps
end
```

When creating new tools or resources, the generators will use the Rails naming convention by default:

```ruby
# app/tools/application_tool.rb
class ApplicationTool < ActionTool::Base
  # Base methods for all tools
end

# app/resources/application_resource.rb
class ApplicationResource < ActionResource::Base
  # Base methods for all resources
end
```

### Easy Sinatra setup

I'll let you check out the dedicated [sinatra integration docs](./docs/sinatra_integration.md).

## 🚀 Quick Start

### Create a Server with Tools and Resources and STDIO transport

```ruby
require 'fast_mcp'

# Create an MCP server
server = FastMcp::Server.new(name: 'my-ai-server', version: '1.0.0')

# Define a tool by inheriting from FastMcp::Tool
class SummarizeTool < FastMcp::Tool
  description "Summarize a given text"

  arguments do
    required(:text).filled(:string).description("Text to summarize")
    optional(:max_length).filled(:integer).description("Maximum length of summary")
  end

  def call(text:, max_length: 100)
    # Your summarization logic here
    text.split('.').first(3).join('.') + '...'
  end
end

# Register the tool with the server
server.register_tool(SummarizeTool)

# Create a resource by inheriting from FastMcp::Resource
class StatisticsResource < FastMcp::Resource
  uri "data/statistics"
  resource_name "Usage Statistics"
  description "Current system statistics"
  mime_type "application/json"

  def content
    JSON.generate({
      users_online: 120,
      queries_per_minute: 250,
      popular_topics: ["Ruby", "AI", "WebDev"]
    })
  end
end

# Register the resource with the server
server.register_resource(StatisticsResource)

# Start the server
server.start
```

## 🧪 Testing with the inspector

MCP has developed a very [useful inspector](https://github.com/modelcontextprotocol/inspector).
You can use it to validate your implementation. I suggest you use the examples I provided with this project as an easy boilerplate.
Clone this project, then give it a go !

```shell
npx @modelcontextprotocol/inspector examples/server_with_stdio_transport.rb
```

Or to test with an SSE transport using a rack middleware:

```shell
npx @modelcontextprotocol/inspector examples/rack_middleware.rb
```

Or to test over SSE with an authenticated rack middleware:

```shell
npx @modelcontextprotocol/inspector examples/authenticated_rack_middleware.rb
```

You can test your custom implementation with the official MCP inspector by using:

```shell
# Test with a stdio transport:
npx @modelcontextprotocol/inspector path/to/your_ruby_file.rb

# Test with an HTTP / SSE server. In the UI select SSE and input your address.
npx @modelcontextprotocol/inspector
```

#### Sinatra

```ruby
# app.rb
require 'sinatra'
require 'fast_mcp'

use FastMcp::RackMiddleware.new(name: 'my-ai-server', version: '1.0.0') do |server|
  # Register tools and resources here
  server.register_tool(SummarizeTool)
end

get '/' do
  'Hello World!'
end
```

### Integrating with Claude Desktop

Add your server to your Claude Desktop configuration at:

- macOS: `~/Library/Application Support/Claude/claude_desktop_config.json`
- Windows: `%APPDATA%\Claude\claude_desktop_config.json`

```json
{
  "mcpServers": {
    "my-great-server": {
      "command": "ruby",
      "args": ["/Users/path/to/your/awesome/fast-mcp/server.rb"]
    }
  }
}
```

## How to add a MCP server to Claude, Cursor, or other MCP clients?

Please refer to [configuring_mcp_clients](docs/configuring_mcp_clients.md)

## 📊 Supported Specifications

| Feature                                         | Status                                                    |
| ----------------------------------------------- | --------------------------------------------------------- |
| ✅ **JSON-RPC 2.0**                             | Full implementation for communication                     |
| ✅ **Tool Definition & Calling**                | Define and call tools with rich argument types            |
| ✅ **Resource & Resource Templates Management** | Create, read, update, and subscribe to resources          |
| ✅ **Transport Options**                        | STDIO, HTTP, and SSE for flexible integration             |
| ✅ **Framework Integration**                    | Rails, Sinatra, Hanami, and any Rack-compatible framework |
| ✅ **Authentication**                           | Secure your AI endpoints with token authentication        |
| ✅ **Schema Support**                           | Full JSON Schema for tool arguments with validation       |
| ✅ **Structured Tool Output**                   | Output schemas, structured content, and JSON text fallback |
| ✅ **Prompts**                                  | Register and render reusable argument-aware prompts       |
| ✅ **Request Filtering**                        | Enforced in-place tool and resource visibility            |
| ✅ **Machine-readable Errors**                  | Application-defined error envelopes without backtraces    |

## 🗺️ Use Cases

- 🤖 **AI-powered Applications**: Connect LLMs to your Ruby app's functionality
- 📊 **Real-time Dashboards**: Build dashboards with live AI-generated insights
- 🔗 **Microservice Communication**: Use MCP as a clean protocol between services
- 📚 **Interactive Documentation**: Create AI-enhanced API documentation
- 💬 **Chatbots and Assistants**: Build AI assistants with access to your app's data

## 🔒 Security Features

Fast MCP includes built-in security features to protect your applications:

### DNS Rebinding Protection

The HTTP/SSE transport validates the Origin header on all incoming connections to prevent DNS rebinding attacks, which could allow malicious websites to interact with local MCP servers.

```ruby
# Configure allowed origins (defaults to ['localhost', '127.0.0.1'])
FastMcp.rack_middleware(app,
  allowed_origins: ['localhost', '127.0.0.1', 'your-domain.com', /.*\.your-domain\.com/],
  localhost_only: false,
  allowed_ips: ['192.168.1.1', '10.0.0.1'],
  # other options...
)
```

### New options in 1.8.0

| Option | Transport | Default | Description |
|---|---|---|---|
| `protocol_versions:` | `Server.new` | `HANDSHAKE_PROTOCOL_VERSIONS` | Cap the list of advertised handshake versions |
| `expose_internal_errors:` | `Server.new` | `false` | Forward exception messages to the client in `-32603` responses |
| `max_request_bytes:` | `RackTransport`, `StdioTransport` | `4 * 1024 * 1024` (Rack) / `nil` (stdio) | Body/line limit; over-limit → HTTP 413 or `-32600` |
| `cors_allowed_origins:` | `RackTransport` | same as `allowed_origins:` | Origins reflected in `Access-Control-Allow-Origin`; disallowed → no header |
| `require_sse_session:` | `RackTransport` | `true` | Require a known `sessionId` on every POST; missing → 400, unknown → 404 |
| `allow_sse_reconnect_takeover:` | `RackTransport` | `false` | Allow a duplicate GET to take over an existing SSE stream |
| `sse_idle_timeout:` | `RackTransport` | `30 * 60` (30 min) | Reap idle SSE clients after this many seconds |
| `input:` / `output:` | `StdioTransport` | `$stdin` / `$stdout` | Redirect IO so that log lines never corrupt the JSON stream |
| `token_verifier:` / `required_scopes:` | `AuthenticatedRackTransport` | `nil` | **Reserved** — OAuth 2.1 hook (not implemented; see docs) |

### Authentication

Fast MCP supports token-based authentication for all connections:

```ruby
# Enable authentication
FastMcp.authenticated_rack_middleware(app,
  auth_token: 'your-secret-token',
  # other options...
)
```

For per-user credentials, CIDR allowlists, or composed authentication, pass an
`authenticator:` to `FastMcp.rack_middleware`. See
[Security](docs/security.md).

## 📖 Documentation

- [🧩 Integration Guide](docs/integration_guide.md)
- [🛤️ Rails Integration](docs/rails_integration.md)
- [🌐 Sinatra Integration](docs/sinatra_integration.md)
- [📚 Resources](docs/resources.md)
- [🛠️ Tools](docs/tools.md)
- [💬 Prompts](docs/prompts.md)
- [🔒 Security](docs/security.md)
- [🎯 Dynamic Filtering](docs/filtering.md)

## 💻 Examples

Check out the [examples directory](examples) for more detailed examples:

- **🔨 Basic Examples**:

  - [Simple Server](examples/server_with_stdio_transport.rb)
  - [Tool Examples](examples/tool_examples.rb)

- **🌐 Web Integration**:
  - [Rack Middleware](examples/rack_middleware.rb)
  - [Authenticated Endpoints](examples/authenticated_rack_middleware.rb)

## 🧪 Requirements

- Ruby 3.2+

## 👥 Contributing

We welcome contributions to Fast MCP! Here's how you can help:

1. Fork the repository
2. Create your feature branch (`git checkout -b my-new-feature`)
3. Commit your changes (`git commit -am 'Add some feature'`)
4. Push to the branch (`git push origin my-new-feature`)
5. Create a new Pull Request

Please read our [Contributing Guide](CONTRIBUTING.md) for more details.

## 📄 License

This project is available as open source under the terms of the [MIT License](https://opensource.org/licenses/MIT).

## Reference implementation

[`steveoro/graph_mem`](https://github.com/steveoro/graph_mem) is the reference consumer of
fast-mcp 1.8.0. Every new server feature has at least one real use there:

| fast-mcp 1.8.0 feature | graph_mem 1.53.0 usage |
|---|---|
| `HANDSHAKE_PROTOCOL_VERSIONS`, `protocol_versions:`, `negotiate_protocol_version` | `lib/graph_mem/mcp_streamable_http_transport.rb#resolve_session`; stdio runner |
| `supported_protocol_version?` | `MCP-Protocol-Version` header check in the same transport |
| `StdioTransport` `input:` / `output:` | `bin/mcp_stdio_runner.rb` (clean stdout) |
| `max_request_bytes`, `cors_allowed_origins`, `require_sse_session`, `allow_sse_reconnect_takeover`, `sse_idle_timeout` | `config/initializers/fast_mcp.rb` legacy `/mcp/sse` options |
| `send_message_to`, `remove_subscriber` | `McpStreamableHttpTransport#send_message_to`, `close_session` + reaper |
| Strict JSON-RPC (`-32700/-32600/-32603`, silent notifications), `expose_internal_errors:` | stdio path; mirrored in graph_mem's Streamable HTTP transport |
| `token_verifier:` (reserved, not implemented) | Deliberately not used; graph_mem keeps its static bearer + IP policy (`GraphMem::McpAccessPolicy`) |

## 🙏 Acknowledgments

- The [Model Context Protocol](https://github.com/modelcontextprotocol) team for creating the specification
- The [Dry-Schema](https://github.com/dry-rb/dry-schema) team for the argument validation.
- All contributors to this project
