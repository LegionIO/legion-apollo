# frozen_string_literal: true

require 'legion/logging'
require_relative 'helpers/tag_normalizer'

# Self-registering route module for legion-apollo.
# All routes previously defined in LegionIO/lib/legion/api/apollo.rb now live here
# and are mounted via Legion::API.register_library_routes when legion-apollo boots.
#
# LegionIO/lib/legion/api/apollo.rb is preserved for backward compatibility but guards
# its registration with defined?(Legion::Apollo::Routes) so double-registration is avoided.

module Legion
  module Apollo
    # Sinatra route module for Apollo API endpoints. Self-registers at boot.
    module Routes # rubocop:disable Metrics/ModuleLength
      def self.registered(app)
        app.helpers ApolloHelpers
        register_status_route(app)
        register_stats_route(app)
        register_query_route(app)
        register_ingest_route(app)
        register_related_route(app)
        register_maintenance_route(app)
        register_graph_route(app)
        register_expertise_route(app)
      end

      def self.register_status_route(app)
        app.get '/api/apollo/status' do
          available      = apollo_runner_available?
          data_connected = apollo_data_connected?
          status_code    = available && data_connected ? 200 : 503

          json_response({ available: available, data_connected: data_connected },
                        status_code: status_code)
        end
      end

      def self.register_stats_route(app)
        app.get '/api/apollo/stats' do
          halt 503, json_error('apollo_unavailable', 'apollo is not available', status_code: 503) unless apollo_loaded?

          stats = apollo_stats
          if stats[:error]
            halt 503, json_error('apollo_stats_unavailable', stats[:error], status_code: 503)
          else
            json_response(stats)
          end
        end
      end

      def self.register_query_route(app) # rubocop:disable Metrics/MethodLength,Metrics/AbcSize,Metrics/CyclomaticComplexity,Metrics/PerceivedComplexity
        app.post '/api/apollo/query' do
          unless apollo_api_available?
            halt 503, json_error('apollo_unavailable', 'apollo is not available', status_code: 503)
          end

          body = parse_request_body
          default_limit = defined?(Legion::Settings) ? (Legion::Settings[:apollo]&.dig(:default_limit) || 5) : 5
          result = Legion::Apollo.query(
            text:           body[:query],
            limit:          body[:limit] || default_limit,
            min_confidence: body[:min_confidence] || 0.3,
            status:         body[:status] || [:confirmed],
            tags:           body[:tags],
            domain:         body[:domain],
            agent_id:       body[:agent_id] || 'api',
            scope:          normalize_scope(body[:scope])
          )
          json_response(result, status_code: apollo_status_code(result))
        end
      end

      def self.register_ingest_route(app) # rubocop:disable Metrics/MethodLength,Metrics/AbcSize,Metrics/CyclomaticComplexity,Metrics/PerceivedComplexity
        app.post '/api/apollo/ingest' do
          unless apollo_api_available?
            halt 503, json_error('apollo_unavailable', 'apollo is not available', status_code: 503)
          end

          body = parse_request_body
          max_tags = defined?(Legion::Settings) ? (Legion::Settings[:apollo]&.dig(:max_tags) || 20) : 20
          # TagNormalizer hard-caps to MAX_TAGS=20 internally; clamp here to make that limit explicit.
          effective_max_tags = [max_tags, Legion::Apollo::Helpers::TagNormalizer::MAX_TAGS].min
          tags = Legion::Apollo::Helpers::TagNormalizer.normalize(Array(body[:tags])).first(effective_max_tags)
          result = Legion::Apollo.ingest(
            content:          body[:content],
            content_type:     body[:content_type] || :observation,
            tags:             tags,
            source_agent:     body[:source_agent] || 'api',
            source_provider:  body[:source_provider],
            source_channel:   body[:source_channel] || 'rest_api',
            knowledge_domain: body[:knowledge_domain],
            context:          body[:context] || {},
            scope:            normalize_scope(body[:scope])
          )
          json_response(result, status_code: apollo_status_code(result, success_status: 201))
        end
      end

      def self.register_related_route(app)
        app.get '/api/apollo/entries/:id/related' do
          halt 503, json_error('apollo_unavailable', 'apollo is not available', status_code: 503) unless apollo_loaded?

          result = apollo_runner.related_entries(
            entry_id:       params[:id].to_i,
            relation_types: params[:relation_types]&.split(','),
            depth:          (params[:depth] || 2).to_i
          )
          json_response(result)
        end
      end

      def self.register_maintenance_route(app) # rubocop:disable Metrics/MethodLength
        app.post '/api/apollo/maintenance' do
          halt 503, json_error('apollo_unavailable', 'apollo is not available', status_code: 503) unless apollo_loaded?

          body = parse_request_body
          action_str = body[:action]
          unless %w[
            decay_cycle corroboration
          ].include?(action_str)
            halt 400,
                 json_error('invalid_action', 'action must be decay_cycle or corroboration', status_code: 400)
          end

          action = action_str.to_sym

          result = run_maintenance(action)
          json_response(result)
        end
      end

      def self.register_graph_route(app)
        app.get '/api/apollo/graph' do
          halt 503, json_error('apollo_unavailable', 'apollo is not available', status_code: 503) unless apollo_loaded?

          json_response(apollo_graph_topology)
        end
      end

      def self.register_expertise_route(app)
        app.get '/api/apollo/expertise' do
          halt 503, json_error('apollo_unavailable', 'apollo is not available', status_code: 503) unless apollo_loaded?

          json_response(apollo_expertise_map)
        end
      end

      class << self
        private :register_status_route, :register_stats_route, :register_query_route,
                :register_ingest_route, :register_related_route, :register_maintenance_route,
                :register_graph_route, :register_expertise_route
      end

      # Helper methods mixed into the Sinatra app context
      module ApolloHelpers
        include Legion::Logging::Helper

        def apollo_runner_available?
          return false unless defined?(Legion::Extensions::Apollo::Runners::Knowledge)

          required = %i[handle_query handle_ingest related_entries]
          required.all? { |m| Legion::Extensions::Apollo::Runners::Knowledge.respond_to?(m) }
        rescue StandardError => e
          handle_exception(e, level: :debug, operation: :apollo_runner_available?)
          false
        end

        def apollo_loaded?
          apollo_runner_available? && apollo_data_connected?
        end

        def apollo_api_available?
          defined?(Legion::Apollo) && Legion::Apollo.respond_to?(:query) && Legion::Apollo.respond_to?(:ingest)
        rescue StandardError => e
          handle_exception(e, level: :debug, operation: :apollo_api_available?)
          false
        end

        def apollo_data_connected?
          defined?(Legion::Data) && Legion::Data.respond_to?(:connection) && !Legion::Data.connection.nil?
        rescue StandardError => e
          handle_exception(e, level: :debug, operation: :apollo_data_connected?)
          false
        end

        def apollo_runner
          Legion::Extensions::Apollo::Runners::Knowledge
        end

        def normalize_scope(scope)
          value = scope&.to_sym
          %i[global local all].include?(value) ? value : :global
        rescue StandardError => e
          handle_exception(e, level: :debug, operation: :normalize_scope)
          :global
        end

        def apollo_status_code(result, success_status: 200)
          return 202 if result[:success] && result[:mode] == :async
          return success_status if result[:success]

          case result[:error]
          when :no_path_available, :not_started then 503
          else 500
          end
        rescue StandardError => e
          handle_exception(e, level: :debug, operation: :apollo_status_code)
          500
        end

        def apollo_maintenance_runner # rubocop:disable Metrics/MethodLength
          @apollo_maintenance_runner ||= begin
            unless defined?(Legion::Extensions::Apollo::Runners::Maintenance)
              halt 503, json_error('maintenance_unavailable', 'Apollo maintenance runner is not loaded')
            end

            runner = Object.new.extend(Legion::Extensions::Apollo::Runners::Maintenance)
            required = %i[run_decay_cycle check_corroboration]
            unless required.all? { |m| runner.respond_to?(m) }
              halt 503, json_error('maintenance_unavailable', 'Apollo maintenance runner is missing required actions')
            end

            runner
          end
        end

        def run_maintenance(action)
          case action
          when :decay_cycle
            apollo_maintenance_runner.run_decay_cycle
          when :corroboration
            apollo_maintenance_runner.check_corroboration
          end
        end

        def apollo_graph_topology
          return { error: 'Apollo runner unavailable' } unless apollo_runner_available?
          unless apollo_runner.respond_to?(:graph_topology)
            return { error: 'Apollo graph_topology not supported by runner' }
          end

          apollo_runner.graph_topology
        rescue StandardError => e
          handle_exception(e, level: :debug, operation: :apollo_graph_topology)
          { error: 'apollo_graph_topology unavailable' }
        end

        def apollo_expertise_map
          return { error: 'Apollo runner unavailable' } unless apollo_runner_available?
          unless apollo_runner.respond_to?(:expertise_map)
            return { error: 'Apollo expertise_map not supported by runner' }
          end

          apollo_runner.expertise_map
        rescue StandardError => e
          handle_exception(e, level: :debug, operation: :apollo_expertise_map)
          { error: 'apollo_expertise_map unavailable' }
        end

        def apollo_stats
          return { total_entries: 0, error: 'Apollo runner unavailable' } unless apollo_runner_available?
          unless apollo_runner.respond_to?(:stats)
            return { total_entries: 0,
                     error:         'Apollo stats not supported by runner' }
          end

          apollo_runner.stats
        rescue StandardError => e
          handle_exception(e, level: :debug, operation: :apollo_stats)
          { total_entries: 0, error: 'apollo_stats unavailable' }
        end
      end
    end
  end
end
