# Rails Integration

Fast MCP can be mounted as Rack middleware inside Rails. Add the GitHub release
to your Gemfile:

```ruby
gem 'fast-mcp',
    git: 'https://github.com/steveoro/fast-mcp.git',
    tag: 'v1.7.0'
```

Then generate the initializer:

```bash
bin/rails generate fast_mcp:install
```

The generated initializer calls `FastMcp.mount_in_rails`. Register tools,
resources, prompts, filters, and the optional error formatter in its block:

```ruby
FastMcp.mount_in_rails(
  Rails.application,
  name: 'my-application',
  version: '1.0.0',
  path_prefix: '/mcp',
  localhost_only: false,
  allowed_ips: ['10.0.0.0/8'],
  authenticator: MyCredentialAuthenticator.new
) do |server|
  server.register_tools(*ApplicationTool.descendants)
  server.register_resources(*ApplicationResource.descendants)
  server.register_prompts(OrientPrompt)
end
```

When `localhost_only` is omitted, Rails local environments default to loopback
and non-local environments permit remote addresses. An explicit `allowed_ips`
list is always enforced.

## Request principals and filtering

A pluggable authenticator returns a principal that tools can read from
`server.current_request_context[:principal]`. Filters receive the same
`Rack::Request` and are enforced for tool calls and resource reads:

```ruby
server.filter_tools do |_request, tools|
  user = server.current_request_context[:principal]
  tools.select { |tool| tool.visible_to?(user) }
end
```

Use `server.filter_mode = :deny` when filtered tool calls should return an
actionable refusal through `error_formatter`; the default `:hide` reports them
as unknown.

## Reloading

In development, register reloadable application classes from
`Rails.application.config.to_prepare` or rebuild the server there. Avoid
registering the same tool class on several simultaneous server instances:
`tool.server` is class-level state.

See the [Rails demo](../examples/rails-demo-app/), [filtering](filtering.md),
[security](security.md), [tools](tools.md), and [prompts](prompts.md) guides.