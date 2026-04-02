# frozen_string_literal: true

require 'legion/logging'

module Legion
  module Apollo
    module Helpers
      # Confidence constants and predicate helpers for Apollo knowledge entries.
      # DB-dependent methods live in lex-apollo; only pure-function logic here.
      module Confidence
        extend Legion::Logging::Helper

        INITIAL_CONFIDENCE     = 0.5
        CORROBORATION_BOOST    = 0.15
        CONTRADICTION_PENALTY  = 0.20
        DECAY_RATE             = 0.005
        WRITE_GATE_THRESHOLD   = 0.3
        HIGH_CONFIDENCE        = 0.8
        ARCHIVE_THRESHOLD      = 0.1

        STATUSES = %i[pending confirmed disputed deprecated archived].freeze

        CONTENT_TYPES = %i[
          fact observation hypothesis procedure opinion
          question answer summary analysis synthesis
        ].freeze

        module_function

        def valid_status?(status)
          STATUSES.include?(status&.to_sym)
        end

        def valid_content_type?(type)
          CONTENT_TYPES.include?(type&.to_sym)
        end

        def above_write_gate?(confidence)
          confidence.to_f >= WRITE_GATE_THRESHOLD
        end

        def high_confidence?(confidence)
          confidence.to_f >= HIGH_CONFIDENCE
        end

        def apollo_setting(key, default)
          return default unless defined?(Legion::Settings) && !Legion::Settings[:apollo].nil?

          Legion::Settings[:apollo][key] || default
        rescue StandardError => e
          handle_exception(e, level: :debug, operation: 'apollo.helpers.confidence.apollo_setting', key: key)
          default
        end
      end
    end
  end
end
