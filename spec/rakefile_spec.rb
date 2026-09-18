# frozen_string_literal: true

require 'rake'
require 'bundler/gem_tasks'

RSpec.describe 'release Rake tasks' do
  around do |example|
    previous_application = Rake.application
    Rake.application = Rake::Application.new
    Bundler::GemHelper.install_tasks
    load File.expand_path('../Rakefile', __dir__)
    example.run
  ensure
    Rake.application = previous_application
  end

  it 'runs the GitHub-only guard before build, tag, or gem-push prerequisites' do
    expect(Rake::Task['release'].prerequisites).to start_with(
      'assert_github_only_release',
      'build'
    )
  end

  it 'aborts unless RubyGems publishing is explicitly enabled' do
    previous = ENV.delete('ALLOW_RUBYGEMS_PUSH')

    expect { Rake::Task['assert_github_only_release'].invoke }
      .to raise_error(SystemExit)
  ensure
    ENV['ALLOW_RUBYGEMS_PUSH'] = previous
  end
end
