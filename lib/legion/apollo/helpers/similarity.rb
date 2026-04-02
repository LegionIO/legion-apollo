# frozen_string_literal: true

require 'legion/logging'

module Legion
  module Apollo
    module Helpers
      # Pure cosine similarity math and match classification for Apollo vectors.
      module Similarity
        extend Legion::Logging::Helper

        EXACT_MATCH_THRESHOLD     = 0.95
        HIGH_SIMILARITY_THRESHOLD = 0.85
        CORROBORATION_THRESHOLD   = 0.75
        RELATED_THRESHOLD         = 0.5

        module_function

        def cosine_similarity(vec_a, vec_b) # rubocop:disable Metrics/MethodLength,Metrics/AbcSize,Metrics/CyclomaticComplexity
          return 0.0 if vec_a.nil? || vec_b.nil? || vec_a.empty? || vec_b.empty?
          return 0.0 unless vec_a.size == vec_b.size

          dot = 0.0
          mag_a = 0.0
          mag_b = 0.0

          vec_a.size.times do |i|
            a = vec_a[i].to_f
            b = vec_b[i].to_f
            dot   += a * b
            mag_a += a * a
            mag_b += b * b
          end

          denom = Math.sqrt(mag_a) * Math.sqrt(mag_b)
          denom.zero? ? 0.0 : (dot / denom)
        rescue StandardError => e
          handle_exception(
            e,
            level:      :debug,
            operation:  'apollo.helpers.similarity.cosine_similarity',
            vec_a_size: Array(vec_a).size,
            vec_b_size: Array(vec_b).size
          )
          0.0
        end

        def classify_match(similarity) # rubocop:disable Metrics/MethodLength
          case similarity
          when EXACT_MATCH_THRESHOLD..1.0                          then :exact
          when HIGH_SIMILARITY_THRESHOLD...EXACT_MATCH_THRESHOLD   then :high
          when CORROBORATION_THRESHOLD...HIGH_SIMILARITY_THRESHOLD  then :corroboration
          when RELATED_THRESHOLD...CORROBORATION_THRESHOLD          then :related
          else :unrelated
          end
        rescue StandardError => e
          handle_exception(
            e,
            level:      :debug,
            operation:  'apollo.helpers.similarity.classify_match',
            similarity: similarity
          )
          :unrelated
        end
      end
    end
  end
end
