# frozen_string_literal: true

require_relative 'apollo/version'
require_relative 'apollo/settings'

module Legion
  # Apollo client library — query, ingest, and retrieve with smart routing.
  # Routes to a co-located lex-apollo service when available, falls back to
  # RabbitMQ transport, and degrades gracefully when neither is present.
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

      def query(text:, limit: nil, min_confidence: nil, tags: nil, **opts) # rubocop:disable Metrics/MethodLength
        return not_started_error unless started?

        limit ||= apollo_setting(:default_limit, 5)
        min_confidence ||= apollo_setting(:min_confidence, 0.3)

        payload = { text: text, limit: limit, min_confidence: min_confidence, tags: tags, **opts }

        if co_located_reader?
          direct_query(payload)
        elsif transport_available?
          publish_query(payload)
        else
          { success: false, error: :no_path_available }
        end
      end

      def ingest(content:, tags: [], **opts)
        return not_started_error unless started?

        payload = { content: content, tags: Array(tags).first(apollo_setting(:max_tags, 20)), **opts }

        if co_located_writer?
          direct_ingest(payload)
        elsif transport_available?
          publish_ingest(payload)
        else
          { success: false, error: :no_path_available }
        end
      end

      def retrieve(text:, limit: 5, **)
        query(text: text, limit: limit, **)
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
