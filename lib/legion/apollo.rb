# frozen_string_literal: true

require 'digest'
require 'legion/logging'
require_relative 'apollo/version'
require_relative 'apollo/settings'
require_relative 'apollo/helpers/tag_normalizer'
require_relative 'apollo/local'
require_relative 'apollo/runners'
require_relative 'apollo/routes'

module Legion
  # Apollo client library — query, ingest, and retrieve with smart routing.
  # Routes to a co-located lex-apollo service when available, falls back to
  # RabbitMQ transport, and degrades gracefully when neither is present.
  # Supports scope: :global (default), :local (SQLite only), :all (merged).
  module Apollo # rubocop:disable Metrics/ModuleLength
    LIFECYCLE_MUTEX = Mutex.new

    class << self # rubocop:disable Metrics/ClassLength
      include Legion::Logging::Helper

      def start # rubocop:disable Metrics/MethodLength
        LIFECYCLE_MUTEX.synchronize do
          return if @started

          merge_settings
          unless apollo_enabled?
            log.info 'Apollo start skipped because apollo.enabled is false'
            return
          end

          detect_transport
          detect_data
          register_routes
          Legion::Apollo::Local.start

          @started = true
          log.info 'Legion::Apollo started'

          seed_self_knowledge
          Legion::Apollo::Local.hydrate_from_global if Legion::Apollo::Local.started?
        end
      rescue StandardError => e
        handle_exception(e, level: :error, operation: 'apollo.start')
        clear_state
      end

      def shutdown
        LIFECYCLE_MUTEX.synchronize do
          Legion::Apollo::Local.shutdown if defined?(Legion::Apollo::Local) && Legion::Apollo::Local.started?
          log.info 'Legion::Apollo shutdown'
          clear_state
        end
      rescue StandardError => e
        handle_exception(e, level: :warn, operation: 'apollo.shutdown')
        clear_state
      end

      def started?
        @started == true
      end

      def local
        Legion::Apollo::Local
      end

      def query(text:, limit: nil, min_confidence: nil, tags: nil, scope: :global, **opts) # rubocop:disable Metrics/MethodLength,Metrics/AbcSize,Metrics/CyclomaticComplexity,Metrics/ParameterLists
        return not_started_error unless started?

        text = normalize_text_input(text)
        normalized_tags = normalize_tags_input(tags)
        limit          ||= apollo_setting(:default_limit, 5)
        min_confidence ||= apollo_setting(:min_confidence, 0.3)
        log.info { "Apollo query requested scope=#{scope} text_length=#{text.to_s.length} limit=#{limit}" }
        log.debug do
          "Apollo query scope=#{scope} limit=#{limit} min_confidence=#{min_confidence} tags=#{normalized_tags.size}"
        end

        payload = { text: text, limit: limit, min_confidence: min_confidence, tags: normalized_tags, **opts }

        case scope
        when :local then query_local(payload)
        when :all   then query_merged(payload)
        else
          if co_located_reader?
            direct_query(payload)
          elsif transport_available?
            publish_query(payload)
          else
            { success: false, error: :no_path_available }
          end
        end
      end

      def ingest(content:, tags: [], scope: :global, **opts) # rubocop:disable Metrics/MethodLength,Metrics/AbcSize
        return not_started_error unless started?

        normalized_tags = normalize_tags_input(tags)
        normalized_content = normalize_text_input(content)
        normalized_raw_content = normalize_raw_content_input(opts[:raw_content], fallback: normalized_content)
        payload = { **opts, content: normalized_content, raw_content: normalized_raw_content, tags: normalized_tags }
        log.info do
          "Apollo ingest requested scope=#{scope} content_length=#{payload[:content].to_s.length} " \
            "tags=#{payload[:tags].size} source_channel=#{payload[:source_channel]}"
        end
        log.debug do
          "Apollo ingest scope=#{scope} tags=#{payload[:tags].size} source_channel=#{payload[:source_channel]}"
        end

        case scope
        when :local then ingest_local(payload)
        when :all   then ingest_all(payload)
        else
          if co_located_writer?
            direct_ingest(payload)
          elsif transport_available?
            publish_ingest(payload)
          else
            { success: false, error: :no_path_available }
          end
        end
      end

      def retrieve(text:, limit: 5, scope: :global, **)
        query(text: text, limit: limit, scope: scope, **)
      end

      # Graph traversal — delegates to Local::Graph for node-local SQLite store.
      # Follows entity edges of the given relation_type up to depth hops.
      #
      # @param entity_id [Integer] starting entity id
      # @param relation_type [String, nil] edge filter (nil = any)
      # @param depth [Integer] max traversal hops (1..10)
      # @param direction [Symbol] :outbound (default) or :inbound
      # @return [Hash] { success:, nodes:, edges:, count: }
      def graph_query(entity_id:, relation_type: nil, depth: 3, direction: :outbound) # rubocop:disable Metrics/MethodLength
        return not_started_error unless started?
        return { success: false, error: :local_not_started } unless Legion::Apollo::Local.started?

        log.info do
          "Apollo graph query requested entity_id=#{entity_id} relation_type=#{relation_type || 'any'} " \
            "depth=#{depth} direction=#{direction}"
        end
        log.debug do
          "Apollo graph_query entity_id=#{entity_id} relation_type=#{relation_type} " \
            "depth=#{depth} direction=#{direction}"
        end
        Legion::Apollo::Local::Graph.traverse(
          entity_id:     entity_id,
          relation_type: relation_type,
          depth:         depth,
          direction:     direction
        )
      rescue StandardError => e
        handle_exception(
          e,
          level:         :error,
          operation:     'apollo.graph_query',
          entity_id:     entity_id,
          relation_type: relation_type,
          depth:         depth,
          direction:     direction
        )
        { success: false, error: e.message }
      end

      def transport_available?
        @transport_available == true
      end

      def data_available?
        @data_available == true
      end

      private

      def merge_settings # rubocop:disable Metrics/MethodLength
        return unless defined?(Legion::Settings)

        defaults = Legion::Apollo::Settings.default
        current = Legion::Settings[:apollo]
        merged = deep_merge_hash(defaults, current.is_a?(Hash) ? current : {})

        if Legion::Settings.respond_to?(:[]=)
          Legion::Settings[:apollo] = merged
        elsif Legion::Settings.respond_to?(:merge_settings)
          Legion::Settings.merge_settings(:apollo, merged)
        end

        log.info 'Apollo settings merged'
      rescue StandardError => e
        handle_exception(e, level: :warn, operation: 'apollo.merge_settings')
      end

      def deep_merge_hash(defaults, overrides)
        defaults.merge(overrides) do |_key, default_value, override_value|
          if default_value.is_a?(Hash) && override_value.is_a?(Hash)
            deep_merge_hash(default_value, override_value)
          else
            override_value
          end
        end
      end

      def detect_transport
        @transport_available = defined?(Legion::Transport) &&
                               Legion::Settings[:transport][:connected] == true
        log.debug { "Apollo transport detected available=#{@transport_available}" }
      rescue StandardError => e
        handle_exception(e, level: :debug, operation: 'apollo.detect_transport')
        @transport_available = false
      end

      def detect_data
        @data_available = defined?(Legion::Data) &&
                          Legion::Settings[:data][:connected] == true
        log.debug { "Apollo data detected available=#{@data_available}" }
      rescue StandardError => e
        handle_exception(e, level: :debug, operation: 'apollo.detect_data')
        @data_available = false
      end

      def co_located_reader?
        return false unless data_available?

        defined?(Legion::Extensions::Apollo::Runners::Knowledge) &&
          Legion::Extensions::Apollo::Runners::Knowledge.respond_to?(:handle_query)
      rescue StandardError => e
        handle_exception(e, level: :debug, operation: 'apollo.co_located_reader')
        false
      end

      def co_located_writer?
        return false unless data_available?

        defined?(Legion::Extensions::Apollo::Runners::Knowledge) &&
          Legion::Extensions::Apollo::Runners::Knowledge.respond_to?(:handle_ingest)
      rescue StandardError => e
        handle_exception(e, level: :debug, operation: 'apollo.co_located_writer')
        false
      end

      def direct_query(payload)
        log.info do
          "Apollo query using co-located reader text_length=#{payload[:text].to_s.length} " \
            "limit=#{payload[:limit]}"
        end
        Legion::Extensions::Apollo::Runners::Knowledge.handle_query(**normalize_query_payload(payload))
      rescue StandardError => e
        handle_exception(e, level: :error, operation: 'apollo.direct_query', payload_keys: payload.keys)
        { success: false, error: :backend_query_failed, detail: e.message }
      end

      def direct_ingest(payload)
        log.info do
          "Apollo ingest using co-located writer tags=#{Array(payload[:tags]).size} " \
            "source_channel=#{payload[:source_channel]}"
        end
        Legion::Extensions::Apollo::Runners::Knowledge.handle_ingest(**payload)
      rescue StandardError => e
        handle_exception(e, level: :error, operation: 'apollo.direct_ingest', payload_keys: payload.keys)
        { success: false, error: e.message }
      end

      def publish_query(payload)
        require_relative 'apollo/messages/query' unless defined?(Legion::Apollo::Messages::Query)
        Legion::Apollo::Messages::Query.new.publish(Legion::JSON.dump(payload))
        log.info { "Apollo query published asynchronously text_length=#{payload[:text].to_s.length}" }
        { success: true, mode: :async }
      rescue StandardError => e
        handle_exception(e, level: :error, operation: 'apollo.publish_query', payload_keys: payload.keys)
        { success: false, error: e.message }
      end

      def publish_ingest(payload)
        require_relative 'apollo/messages/ingest' unless defined?(Legion::Apollo::Messages::Ingest)
        Legion::Apollo::Messages::Ingest.new.publish(Legion::JSON.dump(payload))
        log.info { "Apollo ingest published asynchronously tags=#{Array(payload[:tags]).size}" }
        { success: true, mode: :async }
      rescue StandardError => e
        handle_exception(e, level: :error, operation: 'apollo.publish_ingest', payload_keys: payload.keys)
        { success: false, error: e.message }
      end

      def query_local(payload) # rubocop:disable Metrics/MethodLength,Metrics/AbcSize
        return { success: false, error: :no_path_available } unless Legion::Apollo::Local.started?

        log.info do
          "Apollo query using local store text_length=#{payload[:text].to_s.length} " \
            "limit=#{payload[:limit]}"
        end
        result = Legion::Apollo::Local.query(**payload.slice(:text, :limit, :min_confidence, :tags,
                                                             :tier, :include_inferences, :include_history,
                                                             :as_of))
        return result unless result[:success]

        entries = normalize_local_entries(Array(result[:results]))
        log.info { "Apollo local query completed count=#{entries.size}" }
        { success: true, entries: entries, count: entries.size, mode: :local }
      rescue StandardError => e
        handle_exception(e, level: :error, operation: 'apollo.query_local', payload_keys: payload.keys)
        { success: false, error: e.message }
      end

      def query_merged(payload) # rubocop:disable Metrics/MethodLength,Metrics/AbcSize,Metrics/CyclomaticComplexity,Metrics/PerceivedComplexity
        log.info do
          "Apollo query using merged backends text_length=#{payload[:text].to_s.length} " \
            "limit=#{payload[:limit]} local_started=#{Legion::Apollo::Local.started?}"
        end
        entries = []
        attempted = false
        any_success = false
        errors = []

        if co_located_reader?
          attempted = true
          global = direct_query(payload)
          if global[:success]
            any_success = true
            entries.concat(normalize_global_entries(Array(global[:entries]))) if global[:entries]
          else
            errors << global[:error]
          end
        end

        if Legion::Apollo::Local.started?
          attempted = true
          local = Legion::Apollo::Local.query(**payload.slice(:text, :limit, :min_confidence, :tags,
                                                              :tier, :include_inferences, :include_history,
                                                              :as_of))
          if local[:success]
            any_success = true
            entries.concat(normalize_local_entries(Array(local[:results]))) if local[:results]
          else
            errors << local[:error]
          end
        end

        if !attempted && transport_available?
          log.info do
            'Apollo merged query falling back to async global transport because no synchronous backends are available'
          end
          return publish_query(payload)
        end

        return { success: false, error: :no_path_available } unless attempted

        unless any_success
          symbol_errors = errors.compact.grep(Symbol).uniq
          return { success: false, error: symbol_errors.first } if symbol_errors.size == 1

          combined_error = errors.compact.map(&:to_s).reject(&:empty?).join('; ')
          combined_error = :upstream_query_failed if combined_error.empty?
          return { success: false, error: combined_error }
        end

        ranked = dedup_and_rank(entries, limit: payload[:limit])
        log.info { "Apollo merged query completed count=#{ranked.size}" }
        { success: true, entries: ranked, count: ranked.size, mode: :merged }
      rescue StandardError => e
        handle_exception(e, level: :error, operation: 'apollo.query_merged', payload_keys: payload.keys)
        { success: false, error: e.message }
      end

      def normalize_query_payload(payload)
        normalized_text = normalize_text_input(payload[:text] || payload[:query])
        payload.merge(text: normalized_text, query: normalized_text)
      end

      def normalize_local_entries(entries) # rubocop:disable Metrics/MethodLength,Metrics/AbcSize
        entries.map do |e|
          hash = e[:content_hash] || Digest::MD5.hexdigest(e[:content].to_s.strip.downcase.gsub(/\s+/, ' '))
          tags = if e[:tags].is_a?(String)
                   begin
                     Legion::JSON.parse(e[:tags])
                   rescue StandardError => ex
                     handle_exception(ex, level: :debug, operation: 'apollo.normalize_local_entries', entry_id: e[:id])
                     []
                   end
                 else
                   Array(e[:tags])
                 end
          { id: e[:id], content: e[:content], raw_content: e[:raw_content] || e[:content], content_hash: hash,
            confidence: e[:confidence] || 0.5, content_type: 'fact', tags: tags, source: :local,
            valid_from: e[:valid_from], valid_to: e[:valid_to] }
        end
      end

      def normalize_global_entries(entries)
        entries.map { |entry| normalize_global_entry(entry) }
      end

      def normalize_global_entry(entry)
        { id: entry[:id], content: entry[:content], raw_content: normalized_raw_content(entry),
          content_hash: normalized_content_hash(entry), confidence: entry[:confidence] || 0.5,
          content_type: entry[:content_type] || 'fact', tags: Array(entry[:tags]), source: :global,
          valid_from: entry[:valid_from], valid_to: entry[:valid_to] }
      end

      def normalized_raw_content(entry)
        entry[:raw_content] || entry[:content]
      end

      def normalized_content_hash(entry)
        entry[:content_hash] || Digest::MD5.hexdigest(entry[:content].to_s.strip.downcase.gsub(/\s+/, ' '))
      end

      def dedup_and_rank(entries, limit:)
        sorted = entries
                 .sort_by { |e| -(e[:confidence] || 0) }
                 .uniq { |e| e[:content_hash] }

        limit ? sorted.first(limit) : sorted
      end

      def ingest_local(payload)
        return { success: false, error: :no_path_available } unless Legion::Apollo::Local.started?

        log.info do
          "Apollo ingest using local store tags=#{Array(payload[:tags]).size} " \
            "source_channel=#{payload[:source_channel]}"
        end
        Legion::Apollo::Local.ingest(**payload)
      rescue StandardError => e
        handle_exception(e, level: :error, operation: 'apollo.ingest_local', payload_keys: payload.keys)
        { success: false, error: e.message }
      end

      def ingest_all(payload) # rubocop:disable Metrics/MethodLength,Metrics/AbcSize,Metrics/CyclomaticComplexity,Metrics/PerceivedComplexity
        log.info do
          "Apollo ingest using all backends tags=#{Array(payload[:tags]).size} " \
            "local_started=#{Legion::Apollo::Local.started?}"
        end
        results = []

        if co_located_writer?
          results << direct_ingest(payload)
        elsif transport_available?
          results << publish_ingest(payload)
        end

        results << Legion::Apollo::Local.ingest(**payload) if Legion::Apollo::Local.started?

        return { success: false, error: :no_path_available } if results.empty?

        overall_success = results.any? { |r| r.respond_to?(:[]) && r[:success] }

        if overall_success
          log.info { "Apollo all-backend ingest completed results=#{results.size}" }
          { success: true, mode: :all, results: results }
        else
          errors = results.select { |r| r.respond_to?(:[]) }.map { |r| r[:error] }.compact.uniq
          error_value = errors.length <= 1 ? errors.first : errors
          { success: false, mode: :all, results: results, error: error_value }
        end
      rescue StandardError => e
        handle_exception(e, level: :error, operation: 'apollo.ingest_all', payload_keys: payload.keys)
        { success: false, error: e.message }
      end

      def seed_self_knowledge
        log.info 'Apollo self-knowledge seed requested'
        Legion::Apollo::Local.seed_self_knowledge if Legion::Apollo::Local.started?
      rescue StandardError => e
        handle_exception(e, level: :warn, operation: 'apollo.seed_self_knowledge')
      end

      def apollo_setting(key, default)
        return default unless defined?(Legion::Settings) && !Legion::Settings[:apollo].nil?

        Legion::Settings[:apollo][key] || default
      rescue StandardError => e
        handle_exception(e, level: :debug, operation: 'apollo.apollo_setting', key: key)
        default
      end

      def apollo_enabled?
        return true unless defined?(Legion::Settings) && Legion::Settings[:apollo].is_a?(Hash)

        Legion::Settings[:apollo].fetch(:enabled, true) != false
      rescue StandardError => e
        handle_exception(e, level: :debug, operation: 'apollo.apollo_enabled')
        true
      end

      def normalize_text_input(value) # rubocop:disable Metrics/CyclomaticComplexity,Metrics/MethodLength
        text = case value
               when String
                 value
               when Array
                 parts = value.filter_map { |entry| extract_text_fragment(entry) }
                 joined = parts.map(&:to_s).map(&:strip).reject(&:empty?).join("\n")
                 joined.empty? ? value.to_s : joined
               when Hash
                 extract_text_fragment(value).to_s
               when nil
                 ''
               else
                 value.to_s
               end
        sanitize_text_input(text)
      end

      def sanitize_text_input(value)
        text = value.to_s.dup
        text = text.encode(Encoding::UTF_8, invalid: :replace, undef: :replace, replace: '')
        text = text.scrub('') unless text.valid_encoding?
        text.delete("\u0000")
      end

      def normalize_raw_content_input(value, fallback:)
        normalized = normalize_text_input(value)
        normalized.strip.empty? ? fallback : normalized
      end

      def normalize_tags_input(tags)
        Legion::Apollo::Helpers::TagNormalizer.normalize(Array(tags)).first(apollo_max_tags)
      rescue StandardError => e
        handle_exception(e, level: :debug, operation: 'apollo.normalize_tags_input')
        Array(tags).map(&:to_s).first(apollo_max_tags)
      end

      def apollo_max_tags
        configured = apollo_setting(:max_tags, Legion::Apollo::Helpers::TagNormalizer::MAX_TAGS)
        limit = configured.nil? ? Legion::Apollo::Helpers::TagNormalizer::MAX_TAGS : configured.to_i
        [limit, Legion::Apollo::Helpers::TagNormalizer::MAX_TAGS].min
      rescue StandardError => e
        handle_exception(e, level: :debug, operation: 'apollo.apollo_max_tags')
        Legion::Apollo::Helpers::TagNormalizer::MAX_TAGS
      end

      def extract_text_fragment(value) # rubocop:disable Metrics/AbcSize,Metrics/CyclomaticComplexity,Metrics/MethodLength,Metrics/PerceivedComplexity
        case value
        when String
          value
        when Array
          value.filter_map { |entry| extract_text_fragment(entry) }.join("\n")
        when Hash
          text = value[:text] || value['text']
          return text.to_s if text.is_a?(String)

          content = value[:content] || value['content']
          return extract_text_fragment(content) unless content.nil?

          %i[query prompt message input value summary].each do |key|
            candidate = value[key] || value[key.to_s]
            return extract_text_fragment(candidate) unless candidate.nil?
          end

          value.values.filter_map { |entry| extract_text_fragment(entry) }.join("\n")
        else
          value.to_s
        end
      end

      def not_started_error
        { success: false, error: :not_started }
      end

      def clear_state
        @started = false
        @transport_available = nil
        @data_available = nil
      end

      def register_routes
        return unless defined?(Legion::API) && Legion::API.respond_to?(:register_library_routes)

        Legion::API.register_library_routes('apollo', Legion::Apollo::Routes)
        log.debug 'Legion::Apollo routes registered with API'
      rescue StandardError => e
        handle_exception(e, level: :warn, operation: 'apollo.register_routes')
      end
    end
  end
end
