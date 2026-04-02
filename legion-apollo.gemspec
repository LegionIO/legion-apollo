# frozen_string_literal: true

require_relative 'lib/legion/apollo/version'

Gem::Specification.new do |spec|
  spec.name = 'legion-apollo'
  spec.version       = Legion::Apollo::VERSION
  spec.authors       = ['Esity']
  spec.email         = ['matthewdiverson@gmail.com']
  spec.summary       = 'Apollo client library for the LegionIO framework'
  spec.description   = 'Client-side Apollo knowledge store API for LegionIO. Provides query, ingest, and retrieve ' \
                       'with smart routing (co-located service, RabbitMQ, or graceful failure).'
  spec.homepage      = 'https://github.com/LegionIO/legion-apollo'
  spec.license       = 'Apache-2.0'
  spec.require_paths = ['lib']
  spec.required_ruby_version = '>= 3.4'
  spec.files = Dir['lib/**/*', 'data/**/*', 'LICENSE', 'README.md', 'CHANGELOG.md']
  spec.extra_rdoc_files = %w[README.md LICENSE CHANGELOG.md]
  spec.metadata = {
    'bug_tracker_uri'       => 'https://github.com/LegionIO/legion-apollo/issues',
    'changelog_uri'         => 'https://github.com/LegionIO/legion-apollo/blob/main/CHANGELOG.md',
    'homepage_uri'          => 'https://github.com/LegionIO/LegionIO',
    'source_code_uri'       => 'https://github.com/LegionIO/legion-apollo',
    'rubygems_mfa_required' => 'true'
  }

  spec.add_dependency 'legion-json',     '>= 1.2.1'
  spec.add_dependency 'legion-logging',  '>= 1.4.3'
  spec.add_dependency 'legion-settings', '>= 1.3.14'

  # Optional at runtime (not declared — guarded by defined?() checks):
  # legion-data      >= 1.6.5  — co-located service detection, privilege checks
  # legion-transport >= 1.3.9  — RabbitMQ message publishing for remote Apollo
  # legion-llm       >= 0.5.11 — embedding generation (LLM.can_embed?)
end
