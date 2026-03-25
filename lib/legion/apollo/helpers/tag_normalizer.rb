# frozen_string_literal: true

module Legion
  module Apollo
    module Helpers
      # Pure-function tag normalization: lowercase, strip invalid chars, dedup, truncate.
      module TagNormalizer
        MAX_TAG_LENGTH = 64
        MAX_TAGS       = 20

        module_function

        def normalize(tags)
          return [] unless tags.is_a?(Array)

          tags
            .map { |t| normalize_one(t) }
            .compact
            .uniq
            .first(MAX_TAGS)
        end

        def normalize_one(tag)
          return nil if tag.nil?

          normalized = tag.to_s.strip.downcase.gsub(/[^a-z0-9_:-]/, '_').squeeze('_')
          normalized = normalized[0, MAX_TAG_LENGTH] if normalized.length > MAX_TAG_LENGTH
          normalized.empty? ? nil : normalized
        end
      end
    end
  end
end
