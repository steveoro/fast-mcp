# frozen_string_literal: true

require 'bundler/gem_tasks'
require 'rspec/core/rake_task'

# This fork ships GitHub-only releases. Bundler's generated release task pushes
# its tag and gem from prerequisites, so this guard must be the first one.
task :assert_github_only_release do
  next if ENV['ALLOW_RUBYGEMS_PUSH'] == '1'

  abort 'RubyGems publishing is disabled. Set ALLOW_RUBYGEMS_PUSH=1 only for an intentional publish.'
end

Rake::Task['release'].prerequisites.unshift('assert_github_only_release')

RSpec::Core::RakeTask.new(:spec)

task default: :spec
