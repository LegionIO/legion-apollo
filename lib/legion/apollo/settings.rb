# frozen_string_literal: true

module Legion
  module Apollo
    # Default configuration values for the Apollo client.
    module Settings
      def self.default
        {
          enabled:        true,
          transport_mode: :auto,
          query_timeout:  5,
          ingest_timeout: 10,
          max_tags:       20,
          default_limit:  5,
          min_confidence: 0.3
        }
      end
    end
  end
end
