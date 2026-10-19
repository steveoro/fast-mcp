# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

`AGENTS.md` holds the contributor rules (Ruby environment, YARD docs on public APIs, release policy); follow it too.

## What this is

A maintained fork (`steveoro/fast-mcp`) of the FastMCP Ruby gem: a server-side implementation of the Model Context Protocol. Gem name `fast-mcp`, `require 'fast_mcp'`, module `FastMcp`. Distributed from GitHub tags only, never RubyGems.

## Commands

Run everything through the project RVM gemset (`.versions.conf`):

```bash
source /usr/share/rvm/scripts/rvm && rvm use ruby-3.4.1@fast_mcp && bundle exec <command>
```

- All tests: `bundle exec rspec`
- One file / example: `bundle exec rspec spec/mcp/server_spec.rb` / `bundle exec rspec spec/mcp/server_spec.rb:123`
- Lint: `bundle exec rubocop`
- Gemspec check: `ruby script/verify_gemspec.rb`
- Do not run `rake release` (guarded by `ALLOW_RUBYGEMS_PUSH`); leave `PUBLISH_TO_RUBYGEMS` unset.
- Run GraphMem's MCP integration and full suites before bumping its pinned FastMCP commit.

## Architecture

- `lib/mcp/server.rb` — `FastMcp::Server` is the core. It holds registered tools, resources and prompts, and `handle_request` dispatches JSON-RPC methods (`tools/list`, `tools/call`, `resources/read`, `prompts/get`, ...). Transports feed it raw JSON plus request headers.
- `lib/mcp/tool.rb`, `resource.rb`, `prompt.rb` — base classes users subclass. Tool arguments are declared with Dry-Schema, which both validates calls and generates the JSON schema shown to clients.
- `lib/mcp/transports/` — `stdio_transport`, `rack_transport` (HTTP + SSE, with DNS-rebinding/origin and IP checks), `authenticated_rack_transport`, all on `base_transport`. `FastMcp.rack_middleware` in `lib/fast_mcp.rb` wires a server into a Rack app; `railtie.rb` and `lib/generators/` cover Rails.
- `lib/mcp/authentication.rb` — request authenticator contract (returns a principal or nil).

### Per-request filtering

`lib/mcp/server_filtering.rb` (mixed into `Server`) lets `filter_tools` / `filter_resources` / `filter_prompts` blocks hide items per request. Key design points:

- Filtering is done **in place** via `visible_tools` / `visible_resources` / `visible_prompts`, not by cloning the server: `register_tool` sets `tool.server = self` on the tool *class*, so a clone would reassign that pointer globally and break per-request isolation.
- The current request is kept in a per-thread, per-server context (`Thread.current[:fast_mcp_request_contexts]`, read through `current_request`). With no request (nil), nothing is filtered and a warning is logged if filters exist.
- Filtered items are also non-callable/non-fetchable, not just unlisted. `filter_mode` (`:hide` default, `:deny`) controls whether such a call reports "not found" or a refusal.

## Tests

`spec/mcp/` mirrors `lib/mcp/`; `spec/integration/` exercises the server end to end. `examples/` and `docs/` hold sample servers and guides.
