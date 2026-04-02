# frozen_string_literal: true

require 'digest'
require 'legion/logging'
require 'socket'
require 'time'
require_relative 'local/graph'
require_relative 'helpers/similarity'

module Legion
  module Apollo
    # Node-local knowledge store backed by SQLite + FTS5.
    # Mirrors Legion::Apollo's public API but stores locally.
    module Local # rubocop:disable Metrics/ModuleLength
      MIGRATION_PATH = File.expand_path('local/migrations', __dir__).freeze

      class << self # rubocop:disable Metrics/ClassLength
        include Legion::Logging::Helper

        def start
          return if @started
          return unless local_enabled?
          return unless data_local_available?

          Legion::Data::Local.register_migrations(name: :apollo_local, path: MIGRATION_PATH)
          @started = true
          log.info 'Legion::Apollo::Local started'
        end

        def shutdown
          @started = false
          log.info 'Legion::Apollo::Local shutdown'
        end

        def started?
          @started == true
        end

        def ingest(content:, tags: [], **opts) # rubocop:disable Metrics/MethodLength,Metrics/AbcSize
          return not_started_error unless started?

          hash = content_hash(content)
          if duplicate?(hash)
            log.info { "Apollo::Local ingest deduplicated hash=#{hash}" }
            return { success: true, mode: :deduplicated }
          end

          log.info do
            "Apollo::Local ingest accepted content_length=#{content.to_s.length} " \
              "tags=#{Array(tags).size} source_channel=#{opts[:source_channel]}"
          end
          log.debug { "Apollo::Local ingest hash=#{hash} tags=#{Array(tags).size} source_channel=#{opts[:source_channel]}" }

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

          log.info { "Apollo::Local ingest stored id=#{id} hash=#{hash}" }
          { success: true, mode: :local, id: id }
        rescue StandardError => e
          handle_exception(
            e,
            level:          :error,
            operation:      'apollo.local.ingest',
            tags:           Array(tags).size,
            source_channel: opts[:source_channel]
          )
          { success: false, error: e.message }
        end

        def upsert(content:, tags: [], **opts) # rubocop:disable Metrics/MethodLength,Metrics/AbcSize
          return not_started_error unless started?

          sorted_tags = Array(tags).map(&:to_s).sort
          tag_json = Legion::JSON.dump(sorted_tags)
          existing = db[:local_knowledge].where(tags: tag_json).first

          if existing
            update_upsert_entry(existing, content, tag_json, opts)
          else
            result = ingest(content: content, tags: sorted_tags, **opts)
            result[:mode] = :inserted if result[:success] && result[:mode] != :deduplicated
            result
          end
        rescue StandardError => e
          handle_exception(
            e,
            level:          :warn,
            operation:      'apollo.local.upsert',
            tags:           Array(tags).size,
            source_channel: opts[:source_channel]
          )
          { success: false, error: e.message }
        end

        def query(text:, limit: nil, min_confidence: nil, tags: nil, **) # rubocop:disable Metrics/MethodLength,Metrics/AbcSize
          return not_started_error unless started?

          limit ||= local_setting(:default_limit, 5)
          min_confidence ||= local_setting(:min_confidence, 0.3)
          multiplier = local_setting(:fts_candidate_multiplier, 3)
          log.info do
            "Apollo::Local query executing text_length=#{text.to_s.length} " \
              "limit=#{limit} min_confidence=#{min_confidence} tag_count=#{Array(tags).size}"
          end
          log.debug { "Apollo::Local query limit=#{limit} min_confidence=#{min_confidence} tags=#{Array(tags).size}" }

          candidates = fts_search(text, limit: limit * multiplier)
          candidates = filter_candidates(candidates, min_confidence: min_confidence, tags: tags)
          candidates = cosine_rerank(text, candidates) if can_rerank?
          results = candidates.first(limit)

          log.info { "Apollo::Local query completed count=#{results.size}" }
          { success: true, results: results, count: results.size, mode: :local }
        rescue StandardError => e
          handle_exception(
            e,
            level:          :error,
            operation:      'apollo.local.query',
            limit:          limit,
            min_confidence: min_confidence,
            tag_count:      Array(tags).size
          )
          { success: false, error: e.message }
        end

        def retrieve(text:, limit: 5, **)
          query(text: text, limit: limit, **)
        end

        def graph
          Legion::Apollo::Local::Graph
        end

        def reset!
          @started = false
          @seeded = false
        end

        def seed_self_knowledge
          return unless started?
          return if @seeded

          files = self_knowledge_files
          return if files.empty?

          count = seed_files(files)
          @seeded = true
          log.info("Apollo::Local seeded #{count} self-knowledge files")
        rescue StandardError => e
          handle_exception(e, level: :warn, operation: 'apollo.local.seed_self_knowledge')
        end

        def seeded?
          @seeded == true
        end

        def query_by_tags(tags:, limit: 50) # rubocop:disable Metrics/MethodLength,Metrics/AbcSize
          return { success: false, error: :not_started } unless started?

          candidates = db[:local_knowledge]
                       .where { expires_at > Time.now.utc.iso8601 }
                       .limit(limit)
                       .all

          results = candidates.select do |row|
            row_tags = parse_tags(row[:tags])
            tags.all? { |t| row_tags.include?(t) }
          end

          log.info { "Apollo::Local query_by_tags completed tag_count=#{tags.size} count=#{results.size}" }
          { success: true, results: results, count: results.size }
        rescue StandardError => e
          handle_exception(
            e,
            level:     :error,
            operation: 'apollo.local.query_by_tags',
            tag_count: tags.size,
            limit:     limit
          )
          { success: false, error: e.message }
        end

        def promote_to_global(tags:, min_confidence: 0.6) # rubocop:disable Metrics/MethodLength,Metrics/AbcSize,Metrics/CyclomaticComplexity,Metrics/PerceivedComplexity
          return { success: false, error: :not_started } unless started?

          entries = query_by_tags(tags: tags)
          unless entries[:success] && entries[:results]&.any?
            log.info { "Apollo::Local promote_to_global skipped tag_count=#{tags.size} reason=no_entries" }
            return { success: true, promoted: 0 }
          end

          promoted = 0
          entries[:results].each do |entry|
            next if entry[:confidence].to_f < min_confidence

            entry_tags = parse_tags(entry[:tags])
            hostname = begin
              ::Socket.gethostname
            rescue StandardError => e
              handle_exception(e, level: :debug, operation: 'apollo.local.resolve_hostname')
              'unknown'
            end
            result = Legion::Apollo.ingest(
              content:        entry[:content],
              tags:           entry_tags + ['promoted_from_local'],
              source_channel: 'local_promotion',
              submitted_by:   "node:#{hostname}",
              confidence:     entry[:confidence],
              scope:          :global
            )
            promoted += 1 if result[:success]
          end

          log.info { "Apollo::Local promote_to_global completed promoted=#{promoted} tag_count=#{tags.size}" }
          { success: true, promoted: promoted }
        rescue StandardError => e
          handle_exception(
            e,
            level:          :error,
            operation:      'apollo.local.promote_to_global',
            tag_count:      tags.size,
            min_confidence: min_confidence
          )
          { success: false, error: e.message }
        end

        def hydrate_from_global # rubocop:disable Metrics/MethodLength,Metrics/AbcSize,Metrics/CyclomaticComplexity,Metrics/PerceivedComplexity
          return { success: false, error: :not_started } unless started?

          local_check = query_by_tags(tags: ['partner'])
          if local_check[:success] && local_check[:results]&.any?
            log.info 'Apollo::Local hydration skipped because local partner data already exists'
            return { success: true, skipped: :local_data_exists }
          end

          unless Legion::Apollo.transport_available? || Legion::Apollo.data_available?
            log.info 'Apollo::Local hydration skipped because global Apollo is unavailable'
            return { success: true, skipped: :global_unavailable }
          end

          global_entries = Legion::Apollo.retrieve(text: 'partner bond', scope: :global, limit: 20)
          unless global_entries[:success] && global_entries[:results]&.any?
            log.info 'Apollo::Local hydration skipped because no global partner data was found'
            return { success: true, skipped: :no_global_data }
          end

          log.info { "Apollo::Local hydration started global_count=#{global_entries[:results].size}" }
          hydrated = 0
          global_entries[:results].each do |entry|
            entry_tags = entry[:tags].is_a?(Array) ? entry[:tags] : []
            clean_tags = entry_tags.reject { |t| t == 'promoted_from_local' } + ['hydrated_from_global']

            result = ingest(
              content:        entry[:content],
              tags:           clean_tags,
              confidence:     ((entry[:confidence] || 0.5) * 0.9).round(10),
              source_channel: 'global_hydration'
            )
            hydrated += 1 if result[:success]
          end

          log.info { "Apollo::Local hydration completed hydrated=#{hydrated}" }
          { success: true, hydrated: hydrated }
        rescue StandardError => e
          handle_exception(e, level: :error, operation: 'apollo.local.hydrate_from_global')
          { success: false, error: e.message }
        end

        private

        def self_knowledge_files
          seed_dir = File.join(File.expand_path('../../..', __dir__), 'data', 'self-knowledge')
          return [] unless File.directory?(seed_dir)

          Dir[File.join(seed_dir, '*.md')]
        end

        def seed_files(files)
          count = 0
          files.each do |path|
            count += 1 if seed_single_file(path)
          end
          count
        end

        def seed_single_file(path)
          content = File.read(path)
          return false if content.strip.empty?

          tags = ['legionio', 'self-knowledge', File.basename(path, '.md')]
          result = ingest(content: content, tags: tags, source_channel: 'self-knowledge',
                          submitted_by: 'legion-apollo', confidence: 0.9)
          return false unless result[:success] && result[:mode] != :deduplicated

          ingest_global(content: content, tags: tags) if global_available?
          true
        end

        def ingest_global(content:, tags:)
          log.debug { "Apollo::Local forwarding seed entry to global tag_count=#{Array(tags).size}" }
          Legion::Apollo.ingest(content: content, tags: tags, source_channel: 'self-knowledge',
                                submitted_by: 'legion-apollo', confidence: 0.9, scope: :global)
        rescue StandardError => e
          handle_exception(e, level: :debug, operation: 'apollo.local.ingest_global_seed', tag_count: Array(tags).size)
        end

        def global_available?
          defined?(Legion::Apollo) && Legion::Apollo.started? && Legion::Apollo.respond_to?(:ingest)
        rescue StandardError => e
          handle_exception(e, level: :debug, operation: 'apollo.local.global_available')
          false
        end

        def local_enabled?
          return false unless defined?(Legion::Settings)

          settings = Legion::Settings[:apollo]
          return true if settings.nil?

          local = settings[:local]
          return true if local.nil?

          local[:enabled] != false
        rescue StandardError => e
          handle_exception(e, level: :debug, operation: 'apollo.local.local_enabled')
          true
        end

        def data_local_available?
          defined?(Legion::Data::Local) && Legion::Data::Local.connected?
        rescue StandardError => e
          handle_exception(e, level: :debug, operation: 'apollo.local.data_local_available')
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
        rescue StandardError => e
          handle_exception(e, level: :debug, operation: 'apollo.local.duplicate_check', hash: hash)
          false
        end

        def generate_embedding(content) # rubocop:disable Metrics/MethodLength,Metrics/AbcSize,Metrics/CyclomaticComplexity,Metrics/PerceivedComplexity
          unless defined?(Legion::LLM) && Legion::LLM.respond_to?(:can_embed?) && Legion::LLM.can_embed?
            log.debug 'Apollo::Local embedding skipped because embeddings are unavailable'
            return [nil, nil]
          end

          result = Legion::LLM.embed(content)
          vector = result.is_a?(Hash) ? result[:vector] : result
          if vector.is_a?(Array) && vector.any?
            log.debug { "Apollo::Local embedding generated dimensions=#{vector.size}" }
            [vector, Time.now.utc.strftime('%Y-%m-%dT%H:%M:%S.%LZ')]
          else
            [nil, nil]
          end
        rescue StandardError => e
          handle_exception(
            e,
            level:          :warn,
            operation:      'apollo.local.generate_embedding',
            content_length: content.to_s.length
          )
          [nil, nil]
        end

        def compute_expires_at
          years = local_setting(:retention_years, 5)
          (Time.now.utc + (years * 365.25 * 24 * 3600)).strftime('%Y-%m-%dT%H:%M:%S.%LZ')
        end

        def sync_fts(id, content, tags_json) # rubocop:disable Metrics/MethodLength
          sql = 'INSERT INTO local_knowledge_fts(rowid, content, tags) ' \
                "VALUES (#{id}, #{db.literal(content)}, #{db.literal(tags_json)})"
          db.run(sql)
          log.debug { "Apollo::Local FTS synced id=#{id}" }
        rescue StandardError => e
          handle_exception(
            e,
            level:          :warn,
            operation:      'apollo.local.sync_fts',
            id:             id,
            content_length: content.to_s.length
          )
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
        rescue StandardError => e
          handle_exception(e, level: :debug, operation: 'apollo.local.fts_search', limit: limit, fallback: :ilike)
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

          Legion::JSON.parse(tags_json)
        rescue StandardError => e
          handle_exception(e, level: :debug, operation: 'apollo.local.parse_tags')
          []
        end

        def can_rerank?
          defined?(Legion::LLM) && Legion::LLM.respond_to?(:can_embed?) && Legion::LLM.can_embed?
        end

        def cosine_rerank(text, candidates) # rubocop:disable Metrics/MethodLength,Metrics/AbcSize,Metrics/CyclomaticComplexity,Metrics/PerceivedComplexity
          query_result = Legion::LLM.embed(text)
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
        rescue StandardError => e
          handle_exception(e, level: :warn, operation: 'apollo.local.cosine_rerank', candidate_count: candidates.size)
          candidates
        end

        def parse_embedding(embedding_json)
          return nil if embedding_json.nil? || embedding_json.empty?

          parsed = Legion::JSON.parse(embedding_json)
          parsed.is_a?(Array) ? parsed.map(&:to_f) : nil
        rescue StandardError => e
          handle_exception(e, level: :debug, operation: 'apollo.local.parse_embedding')
          nil
        end

        def local_setting(key, default)
          return default unless defined?(Legion::Settings) && !Legion::Settings[:apollo].nil?

          local = Legion::Settings[:apollo][:local]
          return default if local.nil?

          local[key] || default
        rescue StandardError => e
          handle_exception(e, level: :debug, operation: 'apollo.local.local_setting', key: key)
          default
        end

        def update_upsert_entry(existing, content, tags_json, opts) # rubocop:disable Metrics/MethodLength,Metrics/AbcSize
          content = content.to_s
          new_hash = content_hash(content)
          embedding, embedded_at = generate_embedding(content)
          now = Time.now.utc.strftime('%Y-%m-%dT%H:%M:%S.%LZ')
          expires_at = compute_expires_at

          db[:local_knowledge].where(id: existing[:id]).update(
            content:        content,
            content_hash:   new_hash,
            tags:           tags_json,
            embedding:      embedding ? Legion::JSON.dump(embedding) : nil,
            embedded_at:    embedded_at,
            confidence:     opts.fetch(:confidence, existing[:confidence]),
            expires_at:     expires_at,
            source_channel: opts.fetch(:source_channel, existing[:source_channel]),
            source_agent:   opts.fetch(:source_agent, existing[:source_agent]),
            submitted_by:   opts.fetch(:submitted_by, existing[:submitted_by]),
            updated_at:     now
          )
          rebuild_fts_entry(existing[:id], content, tags_json)
          log.info { "Apollo::Local upsert updated id=#{existing[:id]} hash=#{new_hash}" }
          { success: true, mode: :updated, id: existing[:id] }
        end

        def rebuild_fts_entry(id, content, tags_json) # rubocop:disable Metrics/MethodLength
          db.run("DELETE FROM local_knowledge_fts WHERE rowid = #{id}")
          sync_fts(id, content, tags_json)
          log.debug { "Apollo::Local FTS rebuilt id=#{id}" }
        rescue StandardError => e
          handle_exception(
            e,
            level:          :warn,
            operation:      'apollo.local.rebuild_fts_entry',
            id:             id,
            content_length: content.to_s.length
          )
          nil
        end

        def not_started_error
          { success: false, error: :not_started }
        end
      end
    end
  end
end
