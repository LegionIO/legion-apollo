# frozen_string_literal: true

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

          json_response({ available: available && data_connected, data_connected: data_connected },
                        status_code: status_code)
        end
      end

      def self.register_stats_route(app)
        app.get '/api/apollo/stats' do
          halt 503, json_error('apollo_unavailable', 'apollo is not available', status_code: 503) unless apollo_loaded?

          json_response(apollo_stats)
        end
      end

      def self.register_query_route(app) # rubocop:disable Metrics/MethodLength,Metrics/AbcSize,Metrics/CyclomaticComplexity,Metrics/PerceivedComplexity
        app.post '/api/apollo/query' do
          halt 503, json_error('apollo_unavailable', 'apollo is not available', status_code: 503) unless apollo_loaded?

          body = parse_request_body
          default_limit = defined?(Legion::Settings) ? (Legion::Settings[:apollo]&.dig(:default_limit) || 5) : 5
          result = apollo_runner.handle_query(
            query:          body[:query],
            limit:          body[:limit] || default_limit,
            min_confidence: body[:min_confidence] || 0.3,
            status:         body[:status] || [:confirmed],
            tags:           body[:tags],
            domain:         body[:domain],
            agent_id:       body[:agent_id] || 'api'
          )
          json_response(result)
        end
      end

      def self.register_ingest_route(app) # rubocop:disable Metrics/MethodLength,Metrics/AbcSize,Metrics/CyclomaticComplexity,Metrics/PerceivedComplexity
        app.post '/api/apollo/ingest' do
          halt 503, json_error('apollo_unavailable', 'apollo is not available', status_code: 503) unless apollo_loaded?

          body = parse_request_body
          max_tags = defined?(Legion::Settings) ? (Legion::Settings[:apollo]&.dig(:max_tags) || 20) : 20
          tags = Legion::Apollo::Helpers::TagNormalizer.normalize(Array(body[:tags])).first(max_tags)
          result = apollo_runner.handle_ingest(
            content:          body[:content],
            content_type:     body[:content_type] || :observation,
            tags:             tags,
            source_agent:     body[:source_agent] || 'api',
            source_provider:  body[:source_provider],
            source_channel:   body[:source_channel] || 'rest_api',
            knowledge_domain: body[:knowledge_domain],
            context:          body[:context] || {}
          )
          json_response(result, status_code: 201)
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
          action = body[:action]&.to_sym
          unless %i[
            decay_cycle corroboration
          ].include?(action)
            halt 400,
                 json_error('invalid_action', 'action must be decay_cycle or corroboration', status_code: 400)
          end

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
      module ApolloHelpers # rubocop:disable Metrics/ModuleLength
        def apollo_runner_available?
          return false unless defined?(Legion::Extensions::Apollo::Runners::Knowledge)

          required = %i[handle_query handle_ingest related_entries]
          required.all? { |m| Legion::Extensions::Apollo::Runners::Knowledge.respond_to?(m) }
        rescue StandardError => e
          if defined?(Legion::Logging)
            Legion::Logging.debug("Apollo#apollo_runner_available? check failed: #{e.message}")
          end
          false
        end

        def apollo_loaded?
          apollo_runner_available? && apollo_data_connected?
        end

        def apollo_data_connected?
          defined?(Legion::Data) && Legion::Data.respond_to?(:connection) && !Legion::Data.connection.nil?
        rescue StandardError => e
          Legion::Logging.debug("Apollo#apollo_data_connected? check failed: #{e.message}") if defined?(Legion::Logging)
          false
        end

        def apollo_runner
          Legion::Extensions::Apollo::Runners::Knowledge
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

        def apollo_graph_topology # rubocop:disable Metrics/MethodLength,Metrics/AbcSize,Metrics/CyclomaticComplexity,Metrics/PerceivedComplexity
          return { error: 'Sequel not available' } unless defined?(Sequel) && apollo_data_connected?

          conn = Legion::Data.connection
          entries = conn[:apollo_entries]
          relations = conn[:apollo_relations]

          by_domain = entries.group_and_count(:knowledge_domain).all
                             .to_h { |r| [r[:knowledge_domain] || 'general', r[:count]] }
          by_agent = entries.group_and_count(:source_agent).all
                            .to_h { |r| [r[:source_agent] || 'unknown', r[:count]] }
          by_relation = relations.group_and_count(:relation_type).all
                                 .to_h { |r| [r[:relation_type], r[:count]] }
          disputed   = entries.where(status: 'disputed').count
          confirmed  = entries.where(status: 'confirmed').count
          candidates = entries.where(status: 'candidate').count

          {
            domains:          by_domain,
            agents:           by_agent,
            relation_types:   by_relation,
            total_relations:  relations.count,
            disputed_entries: disputed,
            confirmed:        confirmed,
            candidates:       candidates
          }
        rescue Sequel::Error => e
          { error: e.message }
        end

        def apollo_expertise_map # rubocop:disable Metrics/MethodLength,Metrics/AbcSize,Metrics/CyclomaticComplexity,Metrics/PerceivedComplexity
          return { error: 'Sequel not available' } unless defined?(Sequel) && apollo_data_connected?

          conn = Legion::Data.connection
          rows = conn[:apollo_expertise].order(Sequel.desc(:proficiency)).all

          by_domain = {}
          rows.each do |row|
            domain = row[:domain] || 'general'
            by_domain[domain] ||= []
            by_domain[domain] << {
              agent_id:    row[:agent_id],
              proficiency: row[:proficiency]&.round(3),
              entry_count: row[:entry_count]
            }
          end

          { domains: by_domain, total_agents: rows.map { |r| r[:agent_id] }.uniq.size,
            total_domains: by_domain.size }
        rescue Sequel::Error => e
          { error: e.message }
        end

        def apollo_stats # rubocop:disable Metrics/AbcSize,Metrics/CyclomaticComplexity,Metrics/MethodLength
          return { total_entries: 0, error: 'Sequel not available' } unless defined?(Sequel) && apollo_data_connected?

          entries = Legion::Data.connection[:apollo_entries]
          {
            total_entries:   entries.count,
            by_status:       entries.group_and_count(:status).all.to_h { |r| [r[:status], r[:count]] },
            by_content_type: entries.group_and_count(:content_type).all.to_h { |r| [r[:content_type], r[:count]] },
            recent_24h:      entries.where { created_at >= (Time.now.utc - 86_400) }.count,
            avg_confidence:  entries.avg(:confidence)&.round(3) || 0.0
          }
        rescue Sequel::Error
          { total_entries: 0, error: 'apollo_entries table not available' }
        end
      end
    end
  end
end
