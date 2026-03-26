# frozen_string_literal: true

require 'digest'
require_relative 'apollo/version'
require_relative 'apollo/settings'
require_relative 'apollo/local'
require_relative 'apollo/runners'

module Legion
  # Apollo client library — query, ingest, and retrieve with smart routing.
  # Routes to a co-located lex-apollo service when available, falls back to
  # RabbitMQ transport, and degrades gracefully when neither is present.
  # Supports scope: :global (default), :local (SQLite only), :all (merged).
  module Apollo # rubocop:disable Metrics/ModuleLength
    class << self # rubocop:disable Metrics/ClassLength
      def start
        return if @started

        merge_settings
        detect_transport
        detect_data

        @started = true
        Legion::Logging.info 'Legion::Apollo started' if defined?(Legion::Logging)
      end

      def shutdown
        @started = false
        @transport_available = nil
        @data_available = nil
        Legion::Logging.info 'Legion::Apollo shutdown' if defined?(Legion::Logging)
      end

      def started?
        @started == true
      end

      def local
        Legion::Apollo::Local
      end

      def query(text:, limit: nil, min_confidence: nil, tags: nil, scope: :global, **opts) # rubocop:disable Metrics/MethodLength,Metrics/CyclomaticComplexity,Metrics/ParameterLists
        return not_started_error unless started?

        limit          ||= apollo_setting(:default_limit, 5)
        min_confidence ||= apollo_setting(:min_confidence, 0.3)

        payload = { text: text, limit: limit, min_confidence: min_confidence, tags: tags, **opts }

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

      def ingest(content:, tags: [], scope: :global, **opts) # rubocop:disable Metrics/MethodLength
        return not_started_error unless started?

        payload = { content: content, tags: Array(tags).first(apollo_setting(:max_tags, 20)), **opts }

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
        query(text: text, limit: limit, scope: scope)
      end

      def transport_available?
        @transport_available == true
      end

      def data_available?
        @data_available == true
      end

      private

      def merge_settings
        return unless defined?(Legion::Settings)

        defaults = Legion::Apollo::Settings.default
        Legion::Settings[:apollo] = defaults.merge(Legion::Settings[:apollo] || {})
      rescue StandardError => e
        Legion::Logging.debug("Apollo settings merge failed: #{e.message}") if defined?(Legion::Logging)
      end

      def detect_transport
        @transport_available = defined?(Legion::Transport) &&
                               Legion::Settings[:transport][:connected] == true
      rescue StandardError
        @transport_available = false
      end

      def detect_data
        @data_available = defined?(Legion::Data) &&
                          Legion::Settings[:data][:connected] == true
      rescue StandardError
        @data_available = false
      end

      def co_located_reader?
        return false unless data_available?

        defined?(Legion::Extensions::Apollo::Runners::Knowledge) &&
          Legion::Extensions::Apollo::Runners::Knowledge.respond_to?(:handle_query)
      rescue StandardError
        false
      end

      def co_located_writer?
        return false unless data_available?

        defined?(Legion::Extensions::Apollo::Runners::Knowledge) &&
          Legion::Extensions::Apollo::Runners::Knowledge.respond_to?(:handle_ingest)
      rescue StandardError
        false
      end

      def direct_query(payload)
        Legion::Extensions::Apollo::Runners::Knowledge.handle_query(**payload)
      rescue StandardError => e
        { success: false, error: e.message }
      end

      def direct_ingest(payload)
        Legion::Extensions::Apollo::Runners::Knowledge.handle_ingest(**payload)
      rescue StandardError => e
        { success: false, error: e.message }
      end

      def publish_query(payload)
        require_relative 'apollo/messages/query' unless defined?(Legion::Apollo::Messages::Query)
        Legion::Apollo::Messages::Query.new.publish(Legion::JSON.dump(payload))
        { success: true, mode: :async }
      rescue StandardError => e
        { success: false, error: e.message }
      end

      def publish_ingest(payload)
        require_relative 'apollo/messages/ingest' unless defined?(Legion::Apollo::Messages::Ingest)
        Legion::Apollo::Messages::Ingest.new.publish(Legion::JSON.dump(payload))
        { success: true, mode: :async }
      rescue StandardError => e
        { success: false, error: e.message }
      end

      def query_local(payload)
        return { success: false, error: :no_path_available } unless Legion::Apollo::Local.started?

        result = Legion::Apollo::Local.query(**payload.slice(:text, :limit, :min_confidence, :tags))
        return result unless result[:success]

        entries = normalize_local_entries(Array(result[:results]))
        { success: true, entries: entries, count: entries.size, mode: :local }
      rescue StandardError => e
        { success: false, error: e.message }
      end

      def query_merged(payload) # rubocop:disable Metrics/MethodLength,Metrics/AbcSize,Metrics/CyclomaticComplexity,Metrics/PerceivedComplexity
        entries = []

        if co_located_reader?
          global = direct_query(payload)
          entries.concat(normalize_global_entries(Array(global[:entries]))) if global[:success] && global[:entries]
        end

        if Legion::Apollo::Local.started?
          local = Legion::Apollo::Local.query(**payload.slice(:text, :limit, :min_confidence, :tags))
          entries.concat(normalize_local_entries(Array(local[:results]))) if local[:success] && local[:results]
        end

        if entries.empty? && !co_located_reader? && !Legion::Apollo::Local.started?
          return { success: false, error: :no_path_available }
        end

        ranked = dedup_and_rank(entries, limit: payload[:limit])
        { success: true, entries: ranked, count: ranked.size, mode: :merged }
      rescue StandardError => e
        { success: false, error: e.message }
      end

      def normalize_local_entries(entries) # rubocop:disable Metrics/MethodLength,Metrics/AbcSize
        entries.map do |e|
          hash = e[:content_hash] || Digest::MD5.hexdigest(e[:content].to_s.strip.downcase.gsub(/\s+/, ' '))
          tags = if e[:tags].is_a?(String)
                   begin
                     ::JSON.parse(e[:tags])
                   rescue StandardError
                     []
                   end
                 else
                   Array(e[:tags])
                 end
          { id: e[:id], content: e[:content], content_hash: hash,
            confidence: e[:confidence] || 0.5, content_type: 'fact', tags: tags, source: :local }
        end
      end

      def normalize_global_entries(entries)
        entries.map do |e|
          hash = e[:content_hash] || Digest::MD5.hexdigest(e[:content].to_s.strip.downcase.gsub(/\s+/, ' '))
          { id: e[:id], content: e[:content], content_hash: hash,
            confidence: e[:confidence] || 0.5, content_type: e[:content_type] || 'fact',
            tags: Array(e[:tags]), source: :global }
        end
      end

      def dedup_and_rank(entries, limit:)
        entries
          .sort_by { |e| -(e[:confidence] || 0) }
          .uniq    { |e| e[:content_hash] }
          .first(limit)
      end

      def ingest_local(payload)
        return { success: false, error: :no_path_available } unless Legion::Apollo::Local.started?

        Legion::Apollo::Local.ingest(**payload)
      rescue StandardError => e
        { success: false, error: e.message }
      end

      def ingest_all(payload) # rubocop:disable Metrics/MethodLength
        results = []

        if co_located_writer?
          results << direct_ingest(payload)
        elsif transport_available?
          results << publish_ingest(payload)
        end

        results << Legion::Apollo::Local.ingest(**payload) if Legion::Apollo::Local.started?

        return { success: false, error: :no_path_available } if results.empty?

        { success: true, mode: :all, results: results }
      rescue StandardError => e
        { success: false, error: e.message }
      end

      def apollo_setting(key, default)
        return default unless defined?(Legion::Settings) && !Legion::Settings[:apollo].nil?

        Legion::Settings[:apollo][key] || default
      rescue StandardError
        default
      end

      def not_started_error
        { success: false, error: :not_started }
      end
    end
  end
end
