# frozen_string_literal: true

require 'digest'
require 'legion/logging'
require 'socket'
require 'time'
require_relative 'local/graph'
require_relative 'helpers/confidence'
require_relative 'helpers/similarity'
require_relative 'helpers/tag_normalizer'

module Legion
  module Apollo
    # Node-local knowledge store backed by SQLite + FTS5.
    # Mirrors Legion::Apollo's public API but stores locally.
    module Local # rubocop:disable Metrics/ModuleLength
      MIGRATION_PATH = File.expand_path('local/migrations', __dir__).freeze
      LIFECYCLE_MUTEX = Mutex.new
      WRITE_MUTEX = Mutex.new
      SEED_MUTEX = Mutex.new
      HYDRATION_MUTEX = Mutex.new

      class << self # rubocop:disable Metrics/ClassLength
        include Legion::Logging::Helper

        def start
          LIFECYCLE_MUTEX.synchronize { start_without_lock }
        rescue StandardError => e
          handle_exception(e, level: :error, operation: 'apollo.local.start')
          @started = false
        end

        def shutdown
          LIFECYCLE_MUTEX.synchronize do
            @started = false
            @seeded = false
            log.info 'Legion::Apollo::Local shutdown'
          end
        rescue StandardError => e
          handle_exception(e, level: :warn, operation: 'apollo.local.shutdown')
          @started = false
          @seeded = false
        end

        def started?
          @started == true
        end

        def ingest(content:, tags: [], **opts) # rubocop:disable Metrics/MethodLength
          return not_started_error unless started?

          tags = normalize_tags_input(tags)
          WRITE_MUTEX.synchronize do
            ingest_without_lock(content: content, tags: tags, **opts)
          end
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

          sorted_tags = normalize_tags_input(tags).sort
          tag_json = Legion::JSON.dump(sorted_tags)
          WRITE_MUTEX.synchronize do
            existing = db[:local_knowledge].where(tags: tag_json).first

            if existing
              update_upsert_entry(existing, content, tag_json, opts)
            else
              result = ingest_without_lock(content: content, tags: sorted_tags, **opts)
              result[:mode] = :inserted if result[:success] && result[:mode] != :deduplicated
              result
            end
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

        def query(text:, limit: nil, min_confidence: nil, tags: nil, **opts) # rubocop:disable Metrics/MethodLength,Metrics/AbcSize,Metrics/CyclomaticComplexity
          return not_started_error unless started?

          text = normalize_text_input(text)
          tags = normalize_tags_input(tags)
          limit ||= local_setting(:default_limit, 5)
          min_confidence ||= local_setting(:min_confidence, 0.3)
          multiplier = local_setting(:fts_candidate_multiplier, 3)
          as_of = normalize_temporal_value(opts[:as_of])
          log.info do
            "Apollo::Local query executing text_length=#{text.to_s.length} " \
              "limit=#{limit} min_confidence=#{min_confidence} tag_count=#{Array(tags).size}"
          end
          log.debug { "Apollo::Local query limit=#{limit} min_confidence=#{min_confidence} tags=#{Array(tags).size}" }

          candidates = fts_search(text, limit: limit * multiplier, as_of: as_of)
          include_inferences = opts.fetch(:include_inferences, true)
          include_history = opts.fetch(:include_history, false)
          candidates = filter_candidates(candidates, min_confidence: min_confidence, tags: tags,
                                                     options: { include_inferences: include_inferences,
                                                                include_history: include_history, as_of: as_of })
          candidates = cosine_rerank(text, candidates) if can_rerank?
          results = candidates.first(limit)

          tier = opts[:tier]
          results = results.map { |r| project_tier(r, tier) } if tier

          log.info { "Apollo::Local query completed count=#{results.size}" }
          { success: true, results: results, count: results.size, mode: :local, tier: tier }
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
          LIFECYCLE_MUTEX.synchronize do
            @started = false
            @seeded = false
          end
        end

        def seed_self_knowledge
          return unless started?

          SEED_MUTEX.synchronize { seed_self_knowledge_without_lock }
        rescue StandardError => e
          handle_exception(e, level: :warn, operation: 'apollo.local.seed_self_knowledge')
        end

        def seeded?
          @seeded == true
        end

        def query_by_tags(tags:, limit: 50) # rubocop:disable Metrics/MethodLength
          connection = local_db_connection
          tags = normalize_tags_input(tags)
          return { success: false, error: :not_started } unless local_db_usable?(connection)

          results = query_by_tags_via_sql(connection, tags: tags, limit: limit)

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
          return { success: false, error: :not_started } unless local_db_usable?(local_db_connection)

          tags = normalize_tags_input(tags)
          entries = query_by_tags(tags: tags)
          return entries unless entries[:success]

          unless entries[:results]&.any?
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
              raw_content:    entry[:raw_content] || entry[:content],
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

        def hydrate_from_global
          return { success: false, error: :not_started } unless started?

          HYDRATION_MUTEX.synchronize { hydrate_from_global_without_lock }
        rescue StandardError => e
          handle_exception(e, level: :error, operation: 'apollo.local.hydrate_from_global')
          { success: false, error: e.message }
        end

        def version_chain(entry_id:, max_depth: 50) # rubocop:disable Metrics/MethodLength
          return not_started_error unless started?

          chain = []
          current_id = entry_id
          seen = Set.new

          max_depth.times do
            break unless current_id
            break if seen.include?(current_id)

            seen.add(current_id)
            row = db[:local_knowledge].where(id: current_id).first
            break unless row

            chain << row
            current_id = row[:parent_knowledge_id]
          end

          { success: true, chain: chain, count: chain.size }
        rescue StandardError => e
          handle_exception(e, level: :error, operation: 'apollo.local.version_chain', entry_id: entry_id)
          { success: false, error: e.message }
        end

        def source_links_for(entry_id:)
          return not_started_error unless started?

          links = db[:local_source_links].where(entry_id: entry_id).all
          { success: true, links: links, count: links.size }
        rescue StandardError => e
          handle_exception(e, level: :error, operation: 'apollo.local.source_links_for', entry_id: entry_id)
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

        def local_db_connection
          return nil unless started? && data_local_available?

          db
        rescue StandardError => e
          handle_exception(e, level: :debug, operation: 'apollo.local.local_db_connection')
          nil
        end

        def local_db_usable?(connection)
          return false unless started? && connection
          return false if connection.respond_to?(:closed?) && connection.closed?

          connection.test_connection if connection.respond_to?(:test_connection)
          true
        rescue StandardError => e
          handle_exception(e, level: :debug, operation: 'apollo.local.local_db_usable')
          false
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

        def start_without_lock
          return if @started
          return unless local_enabled? && data_local_available?

          Legion::Data::Local.register_migrations(name: :apollo_local, path: MIGRATION_PATH)
          @started = true
          log.info 'Legion::Apollo::Local started'
        end

        def seed_self_knowledge_without_lock
          return if @seeded

          files = self_knowledge_files
          return if files.empty?

          count = seed_files(files)
          @seeded = true
          log.info("Apollo::Local seeded #{count} self-knowledge files")
        end

        def hydrate_from_global_without_lock # rubocop:disable Metrics/MethodLength,Metrics/AbcSize,Metrics/CyclomaticComplexity,Metrics/PerceivedComplexity
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
          entries = Array(global_entries[:entries] || global_entries[:results])
          unless global_entries[:success] && entries.any?
            log.info 'Apollo::Local hydration skipped because no global partner data was found'
            return { success: true, skipped: :no_global_data }
          end

          log.info { "Apollo::Local hydration started global_count=#{entries.size}" }
          hydrated = 0
          entries.each do |entry|
            entry_tags = entry[:tags].is_a?(Array) ? entry[:tags] : []
            clean_tags = entry_tags.reject { |tag| tag == 'promoted_from_local' } + ['hydrated_from_global']

            result = ingest(
              content:        entry[:content],
              raw_content:    entry[:raw_content] || entry[:content],
              tags:           clean_tags,
              confidence:     ((entry[:confidence] || 0.5) * 0.9).round(10),
              source_channel: 'global_hydration',
              valid_from:     entry[:valid_from],
              valid_to:       entry[:valid_to]
            )
            hydrated += 1 if result[:success]
          end

          log.info { "Apollo::Local hydration completed hydrated=#{hydrated}" }
          { success: true, hydrated: hydrated }
        end

        def ingest_without_lock(content:, tags:, **opts) # rubocop:disable Metrics/MethodLength,Metrics/AbcSize
          content = normalize_text_input(content)
          raw_content = normalize_text_input(opts.key?(:raw_content) ? opts[:raw_content] : content)
          hash = content_hash(content)
          return deduplicated_ingest(hash) if duplicate?(hash)

          log.info do
            "Apollo::Local ingest accepted content_length=#{content.to_s.length} " \
              "tags=#{Array(tags).size} source_channel=#{opts[:source_channel]}"
          end
          log.debug { "Apollo::Local ingest hash=#{hash} tags=#{Array(tags).size} source_channel=#{opts[:source_channel]}" }

          metadata = opts.dup
          metadata.delete(:raw_content)
          row = build_ingest_row(content: content, raw_content: raw_content, hash: hash, tags: tags, **metadata)
          id = persist_ingest_row(row, metadata)
          mark_parent_superseded(metadata[:parent_knowledge_id]) if metadata[:parent_knowledge_id]

          log.info { "Apollo::Local ingest stored id=#{id} hash=#{hash}" }
          { success: true, mode: :local, id: id }
        rescue Sequel::UniqueConstraintViolation
          raise unless duplicate?(hash)

          deduplicated_ingest(hash)
        end

        def build_ingest_row(content:, raw_content:, hash:, tags:, **opts) # rubocop:disable Metrics/MethodLength
          is_inference = opts[:is_inference] == true
          default_confidence = is_inference ? Legion::Apollo::Helpers::Confidence::INITIAL_INFERENCE_CONFIDENCE : 1.0
          ingest_metadata_columns(
            content:            content,
            raw_content:        raw_content,
            hash:               hash,
            tags:               tags,
            opts:               opts,
            is_inference:       is_inference,
            default_confidence: default_confidence
          ).merge(embedding_columns(content, opts)).merge(timestamp_columns)
        end

        def ingest_metadata_columns(context)
          ingest_base_columns(context)
            .merge(ingest_lineage_columns(context[:opts]))
            .merge(ingest_temporal_columns(context[:opts]))
        end

        def ingest_base_columns(context)
          opts = context[:opts]
          {
            content:      context[:content],
            raw_content:  context[:raw_content],
            content_hash: context[:hash],
            tags:         serialized_tags(context[:tags]),
            confidence:   opts[:confidence] || context[:default_confidence],
            is_inference: context[:is_inference]
          }.merge(ingest_source_columns(opts))
        end

        def ingest_source_columns(opts)
          { source_channel: opts[:source_channel], source_agent: opts[:source_agent],
            submitted_by: opts[:submitted_by] }
        end

        def ingest_lineage_columns(opts)
          {
            forget_reason:       opts[:forget_reason],
            parent_knowledge_id: opts[:parent_knowledge_id],
            supersession_type:   opts[:supersession_type]
          }
        end

        def ingest_temporal_columns(opts)
          {
            valid_from: normalize_temporal_value(opts[:valid_from]),
            valid_to:   normalize_temporal_value(opts[:valid_to])
          }
        end

        def persist_ingest_row(row, opts = {})
          db.transaction do
            id = db[:local_knowledge].insert(row)
            sync_fts!(id, row[:content], row[:tags])
            create_source_link(id, opts) if opts[:source_uri]
            id
          end
        end

        def create_source_link(entry_id, opts)
          db[:local_source_links].insert(
            entry_id:          entry_id,
            source_uri:        opts[:source_uri],
            source_hash:       opts[:source_hash],
            relevance_score:   opts[:relevance_score] || 1.0,
            extraction_method: opts[:extraction_method],
            created_at:        Time.now.utc.strftime('%Y-%m-%dT%H:%M:%S.%LZ')
          )
        rescue StandardError => e
          handle_exception(e, level: :warn, operation: 'apollo.local.create_source_link', entry_id: entry_id)
        end

        def deduplicated_ingest(hash)
          log.info { "Apollo::Local ingest deduplicated hash=#{hash}" }
          { success: true, mode: :deduplicated }
        end

        def mark_parent_superseded(parent_id)
          return unless parent_id

          db[:local_knowledge].where(id: parent_id).update(is_latest: false)
          log.info { "Apollo::Local marked entry id=#{parent_id} as superseded" }
        rescue StandardError => e
          handle_exception(e, level: :warn, operation: 'apollo.local.mark_parent_superseded', parent_id: parent_id)
        end

        def generate_embedding(content) # rubocop:disable Metrics/MethodLength,Metrics/AbcSize,Metrics/CyclomaticComplexity,Metrics/PerceivedComplexity
          unless defined?(Legion::LLM) && Legion::LLM.respond_to?(:can_embed?) && Legion::LLM.can_embed?
            log.debug 'Apollo::Local embedding skipped because embeddings are unavailable'
            return [nil, nil]
          end

          content = normalize_text_input(content)
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

        def sync_fts!(id, content, tags_json)
          sql = 'INSERT INTO local_knowledge_fts(rowid, content, tags) ' \
                "VALUES (#{id}, #{db.literal(content)}, #{db.literal(tags_json)})"
          db.run(sql)
          log.debug { "Apollo::Local FTS synced id=#{id}" }
        end

        def embedding_columns(content, opts = {})
          embedding, embedded_at = generate_embedding(content)

          {
            embedding:   embedding ? Legion::JSON.dump(embedding) : nil,
            embedded_at: embedded_at,
            expires_at:  opts[:expires_at] || compute_expires_at
          }
        end

        def timestamp_columns
          now = Time.now.utc.strftime('%Y-%m-%dT%H:%M:%S.%LZ')
          { created_at: now, updated_at: now }
        end

        def serialized_tags(tags)
          Legion::JSON.dump(normalize_tags_input(tags))
        end

        def fts_search(text, limit:, as_of: nil) # rubocop:disable Metrics/MethodLength,Metrics/AbcSize
          now = Time.now.utc.strftime('%Y-%m-%dT%H:%M:%S.%LZ')
          return active_knowledge_dataset(now: now, as_of: as_of).limit(limit).all if text.to_s.strip.empty?

          tokens = text.to_s.scan(/[\p{L}\p{N}_]+/)
          return ilike_search(text, now: now, limit: limit, as_of: as_of) if tokens.empty?

          escaped = tokens.map { |t| %("#{t}") }.join(' ')
          temporal_sql, temporal_params = temporal_window_sql(as_of, table_alias: 'lk')
          db.fetch(
            'SELECT lk.* FROM local_knowledge lk ' \
            'INNER JOIN local_knowledge_fts fts ON lk.id = fts.rowid ' \
            "WHERE local_knowledge_fts MATCH ? AND lk.expires_at > ?#{temporal_sql} " \
            'ORDER BY fts.rank LIMIT ?',
            escaped, now, *temporal_params, limit
          ).all
        rescue StandardError => e
          handle_exception(e, level: :debug, operation: 'apollo.local.fts_search', limit: limit, fallback: :ilike)
          ilike_search(text, now: Time.now.utc.strftime('%Y-%m-%dT%H:%M:%S.%LZ'), limit: limit, as_of: as_of)
        end

        def ilike_search(text, now:, limit:, as_of: nil)
          safe_text = text.to_s.gsub('\\', '\\\\\\\\').gsub('%', '\%').gsub('_', '\_')
          active_knowledge_dataset(now: now, as_of: as_of)
            .where(Sequel.lit("content LIKE ? ESCAPE '\\' COLLATE NOCASE", "%#{safe_text}%"))
            .limit(limit)
            .all
        end

        def filter_candidates(candidates, min_confidence:, tags:, options: {}) # rubocop:disable Metrics/CyclomaticComplexity,Metrics/PerceivedComplexity,Metrics/MethodLength,Metrics/AbcSize
          include_inferences = options.fetch(:include_inferences, true)
          include_history = options.fetch(:include_history, false)
          as_of = options[:as_of]
          candidates = candidates.select { |c| (c[:confidence] || 0) >= min_confidence }
          candidates = candidates.select { |c| temporally_valid?(c, as_of) }
          candidates = candidates.reject { |c| [1, true].include?(c[:is_inference]) } unless include_inferences
          unless include_history
            candidates = candidates.select { |c| c[:is_latest].nil? || c[:is_latest] == 1 || c[:is_latest] == true }
          end
          if tags && !tags.empty?
            tag_set = Array(tags).map(&:to_s)
            candidates = candidates.select do |c|
              entry_tags = parse_tags(c[:tags])
              tag_set.intersect?(entry_tags)
            end
          end
          candidates
        end

        def active_knowledge_dataset(now:, as_of: nil)
          apply_temporal_window(db[:local_knowledge].where(Sequel.lit('expires_at > ?', now)), as_of)
        end

        def apply_temporal_window(dataset, as_of)
          return dataset if as_of.to_s.empty?

          dataset.where(
            Sequel.lit('(valid_from IS NULL OR valid_from <= ?) AND (valid_to IS NULL OR valid_to >= ?)', as_of, as_of)
          )
        end

        def temporal_window_sql(as_of, table_alias:)
          return ['', []] if as_of.to_s.empty?

          [
            " AND (#{table_alias}.valid_from IS NULL OR #{table_alias}.valid_from <= ?) " \
            "AND (#{table_alias}.valid_to IS NULL OR #{table_alias}.valid_to >= ?)",
            [as_of, as_of]
          ]
        end

        def temporally_valid?(row, as_of)
          return true if as_of.to_s.empty?

          valid_from = row[:valid_from]
          valid_to = row[:valid_to]
          (valid_from.nil? || valid_from <= as_of) && (valid_to.nil? || valid_to >= as_of)
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
          text = normalize_text_input(text)
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

        def normalize_text_input(value)
          if defined?(Legion::Apollo) && Legion::Apollo.respond_to?(:normalize_text_input, true)
            return Legion::Apollo.send(:normalize_text_input, value)
          end

          value.to_s
        rescue StandardError => e
          handle_exception(e, level: :debug, operation: 'apollo.local.normalize_text_input')
          value.to_s
        end

        def normalize_temporal_value(value)
          return nil if value.nil?

          text = value.respond_to?(:utc) ? value.utc.strftime('%Y-%m-%dT%H:%M:%S.%LZ') : value.to_s.strip
          return nil if text.empty?

          Time.parse(text).utc.strftime('%Y-%m-%dT%H:%M:%S.%LZ')
        rescue StandardError
          text
        end

        def normalize_tags_input(tags)
          Legion::Apollo::Helpers::TagNormalizer.normalize(Array(tags)).first(max_tags_limit)
        rescue StandardError => e
          handle_exception(e, level: :debug, operation: 'apollo.local.normalize_tags_input')
          Array(tags).map(&:to_s).first(max_tags_limit)
        end

        def max_tags_limit
          configured = if defined?(Legion::Settings) && Legion::Settings[:apollo].is_a?(Hash)
                         Legion::Settings[:apollo][:max_tags]
                       end
          limit = configured.nil? ? Legion::Apollo::Helpers::TagNormalizer::MAX_TAGS : configured.to_i
          [limit, Legion::Apollo::Helpers::TagNormalizer::MAX_TAGS].min
        rescue StandardError => e
          handle_exception(e, level: :debug, operation: 'apollo.local.max_tags_limit')
          Legion::Apollo::Helpers::TagNormalizer::MAX_TAGS
        end

        def query_by_tags_via_sql(connection, tags:, limit:) # rubocop:disable Metrics/AbcSize,Metrics/MethodLength
          now = Time.now.utc.strftime('%Y-%m-%dT%H:%M:%S.%LZ')
          dataset = connection[:local_knowledge].where(Sequel.lit('expires_at > ?', now))

          Array(tags).map(&:to_s).each do |tag|
            dataset = dataset.where(
              Sequel.lit(
                'EXISTS (SELECT 1 FROM json_each(local_knowledge.tags) WHERE json_each.value = ?)',
                tag
              )
            )
          end

          dataset.limit(limit).all
        rescue StandardError => e
          handle_exception(
            e,
            level:     :debug,
            operation: 'apollo.local.query_by_tags_via_sql',
            tag_count: Array(tags).size,
            limit:     limit
          )
          raise unless local_db_usable?(connection)

          query_by_tags_via_ruby(connection, tags: tags, limit: limit)
        end

        def query_by_tags_via_ruby(connection, tags:, limit:)
          raise Sequel::DatabaseConnectionError, 'local database unavailable' unless local_db_usable?(connection)

          candidates = connection[:local_knowledge]
                       .where(Sequel.lit('expires_at > ?', Time.now.utc.strftime('%Y-%m-%dT%H:%M:%S.%LZ')))
                       .all

          candidates.select do |row|
            row_tags = parse_tags(row[:tags])
            tags.all? { |tag| row_tags.include?(tag) }
          end.first(limit)
        end

        def update_upsert_entry(existing, content, tags_json, opts) # rubocop:disable Metrics/MethodLength,Metrics/AbcSize
          content = normalize_text_input(content)
          new_hash = content_hash(content)
          embedding, embedded_at = generate_embedding(content)
          now = Time.now.utc.strftime('%Y-%m-%dT%H:%M:%S.%LZ')
          expires_at = compute_expires_at

          db.transaction do
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
            rebuild_fts_entry!(existing[:id], content, tags_json)
          end
          log.info { "Apollo::Local upsert updated id=#{existing[:id]} hash=#{new_hash}" }
          { success: true, mode: :updated, id: existing[:id] }
        end

        def rebuild_fts_entry!(id, content, tags_json)
          db.run("DELETE FROM local_knowledge_fts WHERE rowid = #{id}")
          sync_fts!(id, content, tags_json)
          log.debug { "Apollo::Local FTS rebuilt id=#{id}" }
        end

        def project_tier(entry, tier) # rubocop:disable Metrics/MethodLength
          case tier
          when :l0
            entry.slice(:id, :content_hash, :confidence, :tags, :source_channel, :is_inference, :is_latest).merge(
              summary: entry[:summary_l0] || entry[:content]&.slice(0, 200)
            )
          when :l1
            entry.slice(:id, :content_hash, :confidence, :tags, :source_channel, :is_inference, :is_latest).merge(
              summary: entry[:summary_l1] || entry[:content]&.slice(0, 1000)
            )
          else
            entry
          end
        end

        def not_started_error
          { success: false, error: :not_started }
        end
      end
    end
  end
end
