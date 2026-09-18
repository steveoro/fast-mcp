# frozen_string_literal: true

require 'bundler/gem_tasks'
require 'rspec/core/rake_task'

# This fork ships GitHub-only releases. Bundler's generated release task pushes
# to RubyGems, so require an explicit opt-in before its action can run.
Rake::Task['release'].actions.unshift(lambda do
  next if ENV['ALLOW_RUBYGEMS_PUSH'] == '1'

  abort 'RubyGems publishing is disabled. Set ALLOW_RUBYGEMS_PUSH=1 only for an intentional publish.'
end)

RSpec::Core::RakeTask.new(:spec)

task default: :spec
