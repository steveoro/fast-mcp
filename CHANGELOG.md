# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.8.0] - 2026-10-23

### Added

- Handshake version negotiation: `HANDSHAKE_PROTOCOL_VERSIONS = %w[2025-11-25 2025-06-18 2025-03-26 2024-11-05]`; `initialize` echoes a supported requested version, otherwise answers the newest (never `2026-07-28`, which has no handshake). `Server.new(protocol_versions: [...])` to cap the list.
- `Server#negotiate_protocol_version`, `#supported_protocol_version?`, `#negotiated_protocol_version` (attr_reader).
- `max_request_bytes` option on `RackTransport` (default 4 MiB → HTTP 413 with `-32600`); an opt-in line-length cap on `StdioTransport` (`max_request_bytes:`, off by default; the newline isn't counted; over-limit → `-32600`, the rest of the line is drained in bounded reads and the next line is still processed).
- Per-session resource subscriptions keyed by session id (`@resource_subscriptions` + `@subscriptions_mutex`); `Server#remove_subscriber(session_key)` returns the count of URIs touched. `RackTransport` keys each POST by its SSE `sessionId`; other embedders pass `session_id:` to `with_request_context`.
- `Transport#send_message_to(client_id, message)` on `RackTransport` for targeted per-session notifications.
- `cors_allowed_origins:` option on `RackTransport`; preflight reflects the allowed `Origin` header, adds `Vary: Origin`; `MCP-Protocol-Version` added to `Access-Control-Allow-Headers` and `Access-Control-Expose-Headers`.
- `require_sse_session:` (default `true`), `allow_sse_reconnect_takeover:` (default `false`), and `sse_idle_timeout:` (default 30 min, measured from the session's last POST) options on `RackTransport` for hardened legacy SSE session semantics.
- `Server#start(**transport_options)` passes `input:`, `output:` and `max_request_bytes:` to `StdioTransport`.
- `expose_internal_errors:` option on `Server` (default `false`); when `false`, exception messages are never forwarded to the client.
- `input:` / `output:` IO options on `StdioTransport` (default `$stdin` / `$stdout`) so that Rails log lines never contaminate the JSON stream.
- Reserved `token_verifier:` and `required_scopes:` names on `AuthenticatedRackTransport` (OAuth 2.1 duck-type interface; **not implemented**: passing either raises `ArgumentError`, so a server can't run unauthenticated by mistake).
- `Server.new(instructions:)` (a String, or a callable that takes the request and returns a String or nil); sent in the `initialize` result when present. `Server#instructions` returns the raw value, `Server#instructions_for(request)` the resolved text.
- `FastMcp::JsonRpc` (`error_response`, `error_id_member`, `valid_id?`): one builder for every JSON-RPC error reply, in the server and all transports.

### Changed (behaviour)

- **Strict JSON-RPC 2.0:** parse errors return `-32700` (was `-32600`); a non-object/array/primitive body returns `-32600` ("JSON-RPC batching is not supported" for arrays); internal errors return `-32603` with the message hidden unless `expose_internal_errors: true`; notifications are **never answered**.
- **Legacy SSE sessions (breaking for clients that POST without a session):** with `require_sse_session: true` (the default) the server issues each session id and sends it in the `endpoint` event (`/messages?sessionId=…`, the GET's query kept); a `POST /messages` without a `sessionId` returns `400 -32600`, an unknown one `404 -32001` (echoing the JSON-RPC id when readable within the body limit); a client-chosen `client_id` is ignored. Replies go only to the SSE stream of the session that sent the request (they were broadcast to every stream). A duplicate `GET /sse` with a connected id returns `409 -32000` unless `allow_sse_reconnect_takeover: true`. Sessions with no POST for `sse_idle_timeout` are closed and unregistered, including Rails-live ones (checked whenever another SSE GET or messages POST arrives). A client that only listens, for example waiting for `resources/updated`, is closed too.
- `unregister_sse_client` / `cleanup_sse_connection` now call `server.remove_subscriber(client_id)` to keep resource-subscription state consistent.

### Fixed

- `resources/unsubscribe` never actually removed subscriptions (was keyed by request id, now keyed by session id, matching subscribe).
- Unknown notifications (e.g. `notifications/cancelled`) got a `-32601` reply with `id: null`; they are now silently dropped.
- A request with `"id": null` is refused with `-32600` (`data: "Request ID must not be null"`) and not executed; id-less request methods are dropped as notifications (MCP Ruby SDK 1.8.1 #612). Client responses are never answered, whatever their id.
- Error replies omit `id` when the request id couldn't be read or isn't valid (missing, `null`, objects, booleans, invalid UTF-8), as the MCP Ruby SDK 1.8.1 does (#615).
- `notifications/resources/list_changed` was sent as `notifications/resources/listChanged`.
- `resources/subscribe` and `resources/unsubscribe` are refused (`-32601`), and list-changed notifications are suppressed, when the capability isn't advertised.
- stdio: frames are stripped as bytes; a frame that isn't valid UTF-8 gets `-32700`, other failures `-32603` without exception text (was `-32000` with the message); a reply that can't be encoded no longer escapes the read loop.
- `RackTransport` internal errors no longer forward the exception message unless `expose_internal_errors: true`.
- `params` that isn't an object gets `-32602` (was `-32603`); a message with an id but no method, result or error gets `-32600` (was dropped).
- `notify_resource_updated` no longer creates an empty subscription entry for every notified URI.
- A takeover's late cleanup of the old stream no longer unregisters the new one.
- The Ruby SDK interop spec actually runs (it pointed at a missing path and used a client API the SDK doesn't have).

## [1.7.1] - 2026-09-22

### Added

- `Server#filter_prompts`, `#visible_prompts` and `#prompt_visible?`, applied to both
  `prompts/list` and `prompts/get`. With no filters configured every prompt is still served, so
  existing servers are unchanged. `filter_mode` hides or denies a filtered prompt the same way it
  does a filtered tool.

## [1.7.0] - 2026-09-18

### Added

- Native MCP prompts with registration, discovery, required arguments, and rendering.
- Opt-in tool output schemas with dual `structuredContent` and mirrored JSON text.
- Ensure-safe request context for response routing and opaque authenticated principals.
- Pluggable constant-time token and CIDR authentication with composable chains.
- Machine-readable tool error formatting without exposing application backtraces.
- In-place tool/resource filtering, enforced across calls, catalogs, reads, and subscriptions.
- `filter_mode` hide/deny behavior and truthful tool-list change notifications.

### Changed

- Hash and Array tool results without output schemas are encoded as JSON text.
- Browser CORS preflight is handled before authentication while retaining IP and Origin checks.
- Explicit `allowed_ips` lists now accept CIDRs and are enforced regardless of
  `localhost_only`; non-local mounts remain unrestricted only when the option is omitted.
- Ruby 3.2 is the minimum supported version.
- Releases from this fork are GitHub-only unless RubyGems publication is explicitly enabled.

### Removed

- Unsafe prerelease `create_filtered_copy` server cloning and its private helpers.
- Obsolete `RackTransport#clear_filtered_servers_cache` and filtered-server cache state.

## [1.7.0.pre.4] - 2026-09-18

### Added

- `Server#filter_mode` selects how a call to a filtered-out tool is answered: `:hide` (default,
  reported as unknown) or `:deny` (reported as a refusal, and routed through `error_formatter`
  when one is configured).
- `Server#visible_tools`, `#visible_resources` and `#tool_visible?` resolve what a given request
  may see, without building anything.

### Changed

- Tool and resource filters are applied **in place** rather than by cloning the server per
  request. Cloning called `register_tool` on the copy, which assigns `tool.server = self` — state
  on the tool *class* — so one request's filtered copy silently repointed every other request's
  tools at it. Since request contexts are keyed by server identity, a concurrent tool call could
  read another request's context, or none at all.
- Filtering now applies to every request path, not just `tools/list`: `tools/call`,
  `resources/list`, `resources/templates/list`, `resources/read` and `resources/subscribe`. A
  filtered tool was previously still callable by name, and a filtered resource still readable by
  URI, which made filtering unusable as the access control the documentation describes. A
  filtered resource is reported as not found, indistinguishable from one that does not exist.
- A server with filters configured but no request in scope logs a warning once, instead of
  silently serving the unfiltered catalogue. Filters need a request to filter against, so a
  transport that never supplies one turns every filter into a no-op that looks like it is working.
- `create_filtered_copy` is deprecated but retained; the request path no longer uses it.
- `RackTransport#clear_filtered_servers_cache` is deprecated and always returns 0: there are no
  server copies to cache. The private cache-key helpers have been removed.

## [1.7.0.pre.3] - 2026-09-18

### Added

- `Server#error_formatter` for machine-readable failure payloads on `tools/call`. When set,
  refused calls are reported as tool errors (`isError: true`) instead of JSON-RPC `-32602`, so a
  client handles one failure shape rather than two.
- Pluggable transport authentication via an `authenticator:` option. An authenticator returns a
  *principal* for an accepted request, which is placed in the per-request context and readable by
  tools through `server.current_request_context[:principal]`. `FastMcp::Authentication` ships a
  constant-time `TokenAuthenticator`, a CIDR-aware `IpAllowlist`, and a `Chain` to compose them.

### Fixed

- Results without an output schema are JSON-encoded when they are a Hash or Array. `to_s`
  produced Ruby inspect syntax (`{name: "value"}`), which is not valid JSON and could not be
  parsed by a client.
- Exception backtraces are no longer sent to the client, on a failed `tools/call` or from the
  outer request rescue; they are logged instead. They disclosed absolute paths and internal
  structure.
- A raising `error_formatter` no longer escalates into a JSON-RPC internal error. The fault is
  logged and the default error text is used instead.
- CORS preflight requests to an MCP path are answered before authentication, so an authenticated
  transport stays reachable from a browser. Preflight responses now advertise `POST` and the
  header carrying the credential, alongside `GET`, `OPTIONS` and `Content-Type`.

## [1.7.0.pre.2] - 2026-09-17

### Added

- Opt-in output schemas with dual `structuredContent` and mirrored JSON text.
- Ensure-safe request-scoped response routing for composite transports.
- Public Rack filtered-server cache invalidation.

## [1.7.0.pre.1] - 2026-09-17

### Added

- Native MCP prompt registration with `prompts/list` and `prompts/get`.
- Prompt capability advertisement and prompt preservation on filtered servers.
- Tool removal and `notifications/tools/list_changed` support.
- RVM-isolated contributor setup and expanded server/stdio integration coverage.

## [1.6.0] - 2025-09-28

### Added

- Tool annotations support for providing hints about tool behavior (readOnlyHint, destructiveHint, etc.) [#96 @pauloarruda](https://github.com/yjacquin/fast-mcp/pull/96)
- GitHub Discussions link in README [#139 @jeznicholson](https://github.com/yjacquin/fast-mcp/pull/139)
- GitHub Sponsors funding configuration [#3d5a7e5 @yjacquin](https://github.com/yjacquin/fast-mcp/commit/3d5a7e5)
- Server hook `on_error_result` for handling tool execution errors [#129 @yannickutard](https://github.com/yjacquin/fast-mcp/pull/129)
- Support for transport option in rack_middleware [#149 @josevalim](https://github.com/yjacquin/fast-mcp/pull/149)

### Fixed

- Tool name validation and override for invalid names [#100 @abdelrahmanothman](https://github.com/yjacquin/fast-mcp/pull/100)
- Typo fixes in sinatra_integration.md [#131 @ilyakamenko](https://github.com/yjacquin/fast-mcp/pull/131) [#102 @anton](https://github.com/yjacquin/fast-mcp/pull/102)
- Add trailing comma to generated initializer template for better Ruby style [#123 @zachhaitz](https://github.com/yjacquin/fast-mcp/pull/123)
- Fix missing commas for params hash [#121 @FanaHOVA](https://github.com/yjacquin/fast-mcp/pull/121)
- RuboCop linting issues resolution [fa6af0b @yjacquin](https://github.com/yjacquin/fast-mcp/commit/fa6af0b)

### Changed

- Updated GitHub Actions dependencies: checkout v4→v5, download-artifact v4→v5 [#141 #142 @dependabot](https://github.com/yjacquin/fast-mcp/pull/141)
- Relax Rack version requirements for better compatibility (>= 2.0, < 4.0) [#133 @eproulx](https://github.com/yjacquin/fast-mcp/pull/133)
- Load generators only when necessary for improved performance [#153 @josevalim](https://github.com/yjacquin/fast-mcp/pull/153)
- Drop schema compiler to use Dry's built-in functionality [#152 @yjacquin](https://github.com/yjacquin/fast-mcp/pull/152), thanks @redox for the help !

## [1.5.0] - 2025-06-01

### Added

- Handle filtering tools and resources [#85 @yjacquin](https://github.com/yjacquin/fast-mcp/pull/85)
- Support for resource templates 🥳 Big thanks to @danielcooper for the contribution [#84 co-authored by @danielcooper and @yjacquin](https://github.com/yjacquin/fast-mcp/pull/84)
- Possibility to authorize requests before tool calls [#79 @EuanEdgar](https://github.com/yjacquin/fast-mcp/pull/79)
- Possibility to read request headers in tool calls [#78 @EuanEdgar](https://github.com/yjacquin/fast-mcp/pull/78)

### Changed

- Bump Dependencies [#86 @aothelal](https://github.com/yjacquin/fast-mcp/pull/86)
- ⚠️ Resources are now stateless, meaning that in-memory resources won't work anymore, they require an external data source such as database, file to read and write too, etc. This was needed for a refactoring of the resource class for the [resource template PR](https://github.com/yjacquin/fast-mcp/pull/84)

### Fixed

- Stop overriding log level to info [#91 @yjacquin](https://github.com/yjacquin/fast-mcp/pull/91)
- Properly handle ping request responses from clients [#89 @yjacquin](https://github.com/yjacquin/fast-mcp/pull/89)
- Add Thread Safety to RackTransport sse_clients [#82 @Kevin-K](https://github.com/yjacquin/fast-mcp/pull/82)

## [1.4.0] - 2025-05-10

### Added

- Conditionnally hidden properties for tool calls (#70) [#70 @yjacquin](https://github.com/yjacquin/fast-mcp/pull/70)
- Metadata to tool call results (#69) [#69 @yjacquin](https://github.com/yjacquin/fast-mcp/pull/69)
- Link to official Discord Server in README.md

## [1.3.2] - 2025-05-08

### Changed

- Logs are now less verbose by default [#64 @yjacquin](https://github.com/yjacquin/fast-mcp/pull/64)

### Fixed

- Fix undefined method `call' for an instance of String error log [#61 @radwo](https://github.com/yjacquin/fast-mcp/pull/61)

## [1.3.1] - 2025-04-30

### Fixed

- Allow ipv4 mapped to ipv6 (#56) [#56 @josevalim](https://github.com/yjacquin/fast-mcp/pull/56)
- Add items to array (#55) [#55 @josevalim](https://github.com/yjacquin/fast-mcp/pull/56)
- Ping is a regular message event (#54) [#56 @josevalim](https://github.com/yjacquin/fast-mcp/pull/56)

## [1.3.0] - 2025-04-28

### Added

- Added automatic forwarding of query params from to the messages endpoint [@yjacquin](https://github.com/yjacquin/fast-mcp/commit/011d968ac982d0b0084f7753dcac5789f66339ee)

### Fixed

- Declare rack as an explicit dependency [#49 @subelsky](https://github.com/yjacquin/fast-mcp/pull/49)
- Fix notifications/initialized response [#51 @yjacquin](https://github.com/yjacquin/fast-mcp/pull/51)

## [1.2.0] - 2025-04-21

### Added

- Security enhancement: Bing only to localhost by default [#44 @yjacquin](https://github.com/yjacquin/fast-mcp/pull/44)
- Prevent AuthenticatedRackMiddleware from blocking other rails routes[#35 @JulianPasquale](https://github.com/yjacquin/fast-mcp/pull/35)
- Stop Forcing reconnections after 30 pings [#42 @zoedsoupe](https://github.com/yjacquin/fast-mcp/pull/42)

## [1.1.0] - 2025-04-13

### Added

- Security enhancement: Added DNS rebinding protection by validating Origin headers [#32 @yjacquin](https://github.com/yjacquin/fast-mcp/pull/32/files)
- Added configuration options for allowed origins in rack middleware [#32 @yjacquin](https://github.com/yjacquin/fast-mcp/pull/32/files)
- Allow to change the SSE and Messages route [#23 @pedrofurtado](https://github.com/yjacquin/fast-mcp/pull/23)
- Fix invalid return value when processing notifications/initialized request [#31 @abMatGit](https://github.com/yjacquin/fast-mcp/pull/31)

## [1.0.0] - 2025-03-30

### Added

- Rails integration improvements via enhanced Railtie support
- Automatic tool and resource registration in Rails applications
- Extended Rails autoload paths for tools and resources directories
- Sample generator templates for resources and tools
- MCP Client configuration documentation as reported by [#8 @sivag-csod](https://github.com/yjacquin/fast-mcp/issues/8)
- Example Ruby on Rails app in the documentation
- `FastMcp.server` now exposes the MCP server to apps that may need it to access resources
- Automated Github Releases through Github Workflow

### Fixed

- Fixed bug with Rack middlewares not being initialized properly.
- Fixed bug with STDIO logging preventing a proper connection with clients [# 11 @cs3b](https://github.com/yjacquin/fast-mcp/issues/11)
- Fixed Rails SSE streaming detection and handling
- Improved error handling in client reconnection scenarios
- Namespace consistency correction (FastMCP -> FastMcp) throughout the codebase

### Improved

- ⚠️ [Breaking] Resource content declaration changes

  - Now resources implement `content` over `default_content`
  - `content` is dynamically called when calling a resource, this implies we can declare dynamic resource contents like:

  ```ruby
  class HighestScoringUsersResource < FastMcp::Resource
  ...
    def content
      User.order(score: :desc).last(5).map(&:as_json)
    end
  end
  ```

- More robust SSE connection lifecycle management
- Optimized test suite with faster execution times
- Better logging for debugging connection issues
- Documentation had outdated examples

## [0.1.0] - 2025-03-12

### Added

- Initial release of the Fast MCP library
- FastMcp::Tool class with multiple definition styles
- FastMcp::Server class with STDIO transport and HTTP / SSE transport
- Rack Integration with authenticated and standard middleware options
- Resource management with subscription capabilities
- Binary resource support
- Examples with STDIO Transport, HTTP & SSE, Rack app
- Initialize lifecycle with capabilities
- Comprehensive test suite with RSpec
