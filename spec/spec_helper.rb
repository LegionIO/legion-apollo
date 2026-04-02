# frozen_string_literal: true

require 'simplecov'
SimpleCov.start do
  add_filter '/spec/'
end

require 'legion/apollo'

# Stub minimal Legion modules for testing
module Legion
  module Logging
    def self.info(_msg) = nil
    def self.debug(_msg) = nil
    def self.warn(_msg) = nil
    def self.error(_msg) = nil
    def self.fatal(_msg) = nil
  end

  module Settings
    @store = {
      apollo:    Legion::Apollo::Settings.default,
      transport: { connected: false },
      data:      { connected: false }
    }

    def self.[](key)
      @store[key]
    end

    def self.[]=(key, val)
      @store[key] = val
    end

    def self.merge_settings(key, val)
      current = @store[key] || {}
      @store[key] = current.merge(val)
    end
  end

  module JSON
    def self.dump(obj) = ::JSON.generate(obj)
    def self.parse(str, **) = ::JSON.parse(str, **)
  end
end

require 'json'

RSpec.configure do |config|
  config.before do
    Legion::Apollo.shutdown if Legion::Apollo.started?
    Legion::Settings[:transport] = { connected: false }
    Legion::Settings[:data] = { connected: false }
    Legion::Settings[:apollo] = Legion::Apollo::Settings.default.dup
  end
end
