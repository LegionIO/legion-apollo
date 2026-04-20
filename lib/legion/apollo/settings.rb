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
          local:          local_defaults,
          versioning:     versioning_defaults,
          expiry:         expiry_defaults
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

      def self.versioning_defaults
        {
          enabled:                  true,
          supersession_threshold:   0.85,
          max_chain_depth:          50
        }
      end

      def self.expiry_defaults
        {
          enabled:            true,
          sweep_interval:     3600,
          warn_before_expiry: 86_400
        }
      end
    end
  end
end
