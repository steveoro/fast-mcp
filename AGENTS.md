# FastMCP Contributor Notes

## Ruby environment

Run Ruby, Bundler, Rake, RSpec, and RuboCop through the project RVM gemset:

```bash
source /usr/share/rvm/scripts/rvm &&
  rvm use ruby-3.4.1@fast_mcp &&
  bundle exec <command>
```

`.versions.conf` is the source of truth for the Ruby and gemset.

## Public APIs

Document basic usage, parameter types, return types, and meaningful errors for
public methods. Prefer concise YARD-style comments.

## Verification

- Tests: `bundle exec rspec`
- Lint: `bundle exec rubocop`
- Run GraphMem's MCP integration and full suites before updating its pinned
  FastMCP commit.

## Releases

- Releases from this fork are GitHub-only unless explicitly changed.
- Do not use `rake release`; it pushes to RubyGems and is guarded by
  `ALLOW_RUBYGEMS_PUSH=1`.
- Leave `PUBLISH_TO_RUBYGEMS` unset so tag workflows skip publication.
- Verify the gemspec, build the gem, and wait for the Ruby matrix before
  creating a stable tag.
