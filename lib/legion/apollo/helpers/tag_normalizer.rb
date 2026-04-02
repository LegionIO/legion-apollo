# frozen_string_literal: true

require 'legion/logging'

module Legion
  module Apollo
    module Helpers
      # Pure-function tag normalization: lowercase, strip invalid chars, dedup, truncate.
      module TagNormalizer
        extend Legion::Logging::Helper

        MAX_TAG_LENGTH = 64
        MAX_TAGS       = 20

        module_function

        def normalize(tags) # rubocop:disable Metrics/MethodLength
          return [] unless tags.is_a?(Array)

          tags
            .map { |t| normalize_one(t) }
            .compact
            .uniq
            .first(MAX_TAGS)
        rescue StandardError => e
          handle_exception(
            e,
            level:     :debug,
            operation: 'apollo.helpers.tag_normalizer.normalize',
            tag_count: Array(tags).size
          )
          []
        end

        def normalize_one(tag) # rubocop:disable Metrics/MethodLength
          return nil if tag.nil?

          normalized = tag.to_s.strip.downcase.gsub(/[^a-z0-9_:-]/, '_').squeeze('_')
          normalized = normalized[0, MAX_TAG_LENGTH] if normalized.length > MAX_TAG_LENGTH
          normalized.empty? ? nil : normalized
        rescue StandardError => e
          handle_exception(
            e,
            level:     :debug,
            operation: 'apollo.helpers.tag_normalizer.normalize_one',
            tag_class: tag.class.to_s
          )
          nil
        end
      end
    end
  end
end
