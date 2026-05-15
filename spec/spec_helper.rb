# frozen_string_literal: true

require 'simplecov'
SimpleCov.start do
  add_filter '/spec/'
end

require 'legion/apollo'

require 'json'

RSpec.configure do |config|
  config.before do
    Legion::Apollo.shutdown if Legion::Apollo.started?
    Legion::Settings.reset!
    Legion::Settings.load
    Legion::Settings.merge_settings(:apollo, Legion::Apollo::Settings.default)
  end
end
