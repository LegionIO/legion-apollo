# frozen_string_literal: true

require 'legion/logging'

module Legion
  module Apollo
    module Runners
      # GAIA knowledge_retrieval shim — delegates to Legion::Apollo.retrieve with scope: :all.
      module Request
        extend Legion::Logging::Helper

        def self.retrieve(text:, limit: 5, **)
          log.info { "Apollo::Runners::Request retrieve delegated text_length=#{text.to_s.length} limit=#{limit}" }
          Legion::Apollo.retrieve(text: text, limit: limit, scope: :all, **)
        end
      end
    end
  end
end
