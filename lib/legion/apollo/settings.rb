# frozen_string_literal: true

module Legion
  module Apollo
    # Default configuration values for the Apollo client.
    module Settings
      def self.default
        {
          enabled:        true,
          max_tags:       20,
          default_limit:  5,
          min_confidence: 0.3,
          local:          local_defaults
        }
      end

      def self.local_defaults
        {
          enabled:                  true,
          retention_years:          5,
          default_query_scope:      :all,
          fts_candidate_multiplier: 3,
          min_confidence:           0.3,
          default_limit:            5
        }
      end
    end
  end
end
