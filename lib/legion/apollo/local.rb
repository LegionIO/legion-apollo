# frozen_string_literal: true

require 'digest'
require 'time'

module Legion
  module Apollo
    # Node-local knowledge store backed by SQLite + FTS5.
    # Mirrors Legion::Apollo's public API but stores locally.
    module Local # rubocop:disable Metrics/ModuleLength
      MIGRATION_PATH = File.expand_path('local/migrations', __dir__).freeze

      class << self # rubocop:disable Metrics/ClassLength
        def start
          return if @started
          return unless local_enabled?
          return unless data_local_available?

          Legion::Data::Local.register_migrations(name: :apollo_local, path: MIGRATION_PATH)
          @started = true
          Legion::Logging.info 'Legion::Apollo::Local started' if defined?(Legion::Logging)
        end

        def shutdown
          @started = false
          Legion::Logging.info 'Legion::Apollo::Local shutdown' if defined?(Legion::Logging)
        end

        def started?
          @started == true
        end

        def ingest(content:, tags: [], **opts) # rubocop:disable Metrics/MethodLength,Metrics/AbcSize
          return not_started_error unless started?

          hash = content_hash(content)
          return { success: true, mode: :deduplicated } if duplicate?(hash)

          embedding, embedded_at = generate_embedding(content)
          now = Time.now.utc.strftime('%Y-%m-%dT%H:%M:%S.%LZ')
          expires = compute_expires_at

          row = {
            content:        content,
            content_hash:   hash,
            tags:           Legion::JSON.dump(Array(tags).first(local_setting(:max_tags, 20))),
            embedding:      embedding ? Legion::JSON.dump(embedding) : nil,
            embedded_at:    embedded_at,
            source_channel: opts[:source_channel],
            source_agent:   opts[:source_agent],
            submitted_by:   opts[:submitted_by],
            confidence:     opts[:confidence] || 1.0,
            expires_at:     expires,
            created_at:     now,
            updated_at:     now
          }

          id = db[:local_knowledge].insert(row)
          sync_fts(id, content, row[:tags])

          { success: true, mode: :local, id: id }
        rescue StandardError => e
          { success: false, error: e.message }
        end

        def query(text:, limit: nil, min_confidence: nil, tags: nil, **) # rubocop:disable Metrics/MethodLength,Metrics/AbcSize
          return not_started_error unless started?

          limit ||= local_setting(:default_limit, 5)
          min_confidence ||= local_setting(:min_confidence, 0.3)
          multiplier = local_setting(:fts_candidate_multiplier, 3)

          candidates = fts_search(text, limit: limit * multiplier)
          candidates = filter_candidates(candidates, min_confidence: min_confidence, tags: tags)
          candidates = cosine_rerank(text, candidates) if can_rerank?
          results = candidates.first(limit)

          { success: true, results: results, count: results.size, mode: :local }
        rescue StandardError => e
          { success: false, error: e.message }
        end

        def retrieve(text:, limit: 5, **)
          query(text: text, limit: limit, **)
        end

        def reset!
          @started = false
        end

        private

        def local_enabled?
          return false unless defined?(Legion::Settings)

          settings = Legion::Settings[:apollo]
          return true if settings.nil?

          local = settings[:local]
          return true if local.nil?

          local[:enabled] != false
        rescue StandardError
          true
        end

        def data_local_available?
          defined?(Legion::Data::Local) && Legion::Data::Local.connected?
        rescue StandardError
          false
        end

        def db
          Legion::Data::Local.connection
        end

        def content_hash(content)
          normalized = content.to_s.strip.downcase.gsub(/\s+/, ' ')
          Digest::MD5.hexdigest(normalized)
        end

        def duplicate?(hash)
          db[:local_knowledge].where(content_hash: hash).any?
        rescue StandardError
          false
        end

        def generate_embedding(content) # rubocop:disable Metrics/MethodLength,Metrics/CyclomaticComplexity,Metrics/PerceivedComplexity
          unless defined?(Legion::LLM) && Legion::LLM.respond_to?(:can_embed?) && Legion::LLM.can_embed?
            return [nil, nil]
          end

          result = Legion::LLM::Embeddings.generate(text: content)
          vector = result.is_a?(Hash) ? result[:vector] : result
          if vector.is_a?(Array) && vector.any?
            [vector, Time.now.utc.strftime('%Y-%m-%dT%H:%M:%S.%LZ')]
          else
            [nil, nil]
          end
        rescue StandardError
          [nil, nil]
        end

        def compute_expires_at
          years = local_setting(:retention_years, 5)
          (Time.now.utc + (years * 365.25 * 24 * 3600)).strftime('%Y-%m-%dT%H:%M:%S.%LZ')
        end

        def sync_fts(id, content, tags_json)
          sql = 'INSERT INTO local_knowledge_fts(rowid, content, tags) ' \
                "VALUES (#{id}, #{db.literal(content)}, #{db.literal(tags_json)})"
          db.run(sql)
        rescue StandardError => e
          Legion::Logging.warn("FTS5 sync failed for id=#{id}: #{e.message}") if defined?(Legion::Logging)
        end

        def fts_search(text, limit:) # rubocop:disable Metrics/MethodLength,Metrics/AbcSize
          escaped = text.to_s.gsub('"', '""')
          now = Time.now.utc.strftime('%Y-%m-%dT%H:%M:%S.%LZ')
          db.fetch(
            'SELECT lk.* FROM local_knowledge lk ' \
            'INNER JOIN local_knowledge_fts fts ON lk.id = fts.rowid ' \
            'WHERE local_knowledge_fts MATCH ? AND lk.expires_at > ? ORDER BY fts.rank LIMIT ?',
            escaped, now, limit
          ).all
        rescue StandardError
          db[:local_knowledge]
            .where(Sequel.lit('expires_at > ?', Time.now.utc.strftime('%Y-%m-%dT%H:%M:%S.%LZ')))
            .where(Sequel.ilike(:content, "%#{text}%"))
            .limit(limit)
            .all
        end

        def filter_candidates(candidates, min_confidence:, tags:)
          candidates = candidates.select { |c| (c[:confidence] || 0) >= min_confidence }
          if tags && !tags.empty?
            tag_set = Array(tags).map(&:to_s)
            candidates = candidates.select do |c|
              entry_tags = parse_tags(c[:tags])
              tag_set.intersect?(entry_tags)
            end
          end
          candidates
        end

        def parse_tags(tags_json)
          return [] if tags_json.nil? || tags_json.empty?

          ::JSON.parse(tags_json)
        rescue StandardError
          []
        end

        def can_rerank?
          defined?(Legion::LLM) && Legion::LLM.respond_to?(:can_embed?) && Legion::LLM.can_embed?
        end

        def cosine_rerank(text, candidates) # rubocop:disable Metrics/MethodLength,Metrics/AbcSize,Metrics/CyclomaticComplexity,Metrics/PerceivedComplexity
          query_result = Legion::LLM::Embeddings.generate(text: text)
          query_vec = query_result.is_a?(Hash) ? query_result[:vector] : query_result
          return candidates unless query_vec.is_a?(Array) && query_vec.any?

          scored = candidates.map do |c|
            entry_vec = parse_embedding(c[:embedding])
            score = if entry_vec
                      Legion::Apollo::Helpers::Similarity.cosine_similarity(query_vec, entry_vec)
                    else
                      0.0
                    end
            c.merge(similarity: score)
          end

          scored.sort_by { |c| -(c[:similarity] || 0) }
        rescue StandardError
          candidates
        end

        def parse_embedding(embedding_json)
          return nil if embedding_json.nil? || embedding_json.empty?

          parsed = ::JSON.parse(embedding_json)
          parsed.is_a?(Array) ? parsed.map(&:to_f) : nil
        rescue StandardError
          nil
        end

        def local_setting(key, default)
          return default unless defined?(Legion::Settings) && !Legion::Settings[:apollo].nil?

          local = Legion::Settings[:apollo][:local]
          return default if local.nil?

          local[key] || default
        rescue StandardError
          default
        end

        def not_started_error
          { success: false, error: :not_started }
        end
      end
    end
  end
end
