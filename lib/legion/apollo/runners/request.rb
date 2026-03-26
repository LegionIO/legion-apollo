# frozen_string_literal: true

module Legion
  module Apollo
    module Runners
      # GAIA knowledge_retrieval shim — delegates to Legion::Apollo.retrieve with scope: :all.
      module Request
        def self.retrieve(text:, limit: 5, **)
          Legion::Apollo.retrieve(text: text, limit: limit, scope: :all)
        end
      end
    end
  end
end
