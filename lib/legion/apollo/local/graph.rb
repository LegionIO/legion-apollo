# frozen_string_literal: true

require 'legion/logging'
require 'time'
require 'set'

module Legion
  module Apollo
    module Local
      # Entity-relationship graph layer backed by local SQLite tables.
      # Entities are schema-flexible (type + name + domain + JSON attributes).
      # Relationships are directional typed edges between two entities.
      # Graph traversal expands one frontier batch per depth to avoid per-node queries.
      module Graph # rubocop:disable Metrics/ModuleLength
        VALID_RELATION_TYPES = %w[AFFECTS OWNED_BY DEPENDS_ON RELATED_TO].freeze

        class << self # rubocop:disable Metrics/ClassLength
          include Legion::Logging::Helper

          # --- Entity CRUD ---

          def create_entity(type:, name:, domain: nil, attributes: {}) # rubocop:disable Metrics/MethodLength
            now = timestamp
            id = db.transaction do
              db[:local_entities].insert(
                entity_type: type.to_s,
                name:        name.to_s,
                domain:      domain&.to_s,
                attributes:  encode(attributes),
                created_at:  now,
                updated_at:  now
              )
            end
            log.info { "Apollo::Local::Graph created entity id=#{id} type=#{type} name=#{name}" }
            { success: true, id: id }
          rescue Sequel::Error => e
            handle_exception(
              e,
              level:       :error,
              operation:   'apollo.local.graph.create_entity',
              entity_type: type,
              name:        name
            )
            { success: false, error: e.message }
          end

          def find_entity(id:)
            row = db[:local_entities].where(id: id).first
            return { success: false, error: :not_found } unless row

            log.debug { "Apollo::Local::Graph found entity id=#{id}" }
            { success: true, entity: decode_entity(row) }
          rescue Sequel::Error => e
            handle_exception(e, level: :error, operation: 'apollo.local.graph.find_entity', entity_id: id)
            { success: false, error: e.message }
          end

          def find_entities_by_type(type:, limit: 50) # rubocop:disable Metrics/MethodLength
            rows = db[:local_entities].where(entity_type: type.to_s).limit(limit).all
            log.debug { "Apollo::Local::Graph found entities type=#{type} count=#{rows.size}" }
            { success: true, entities: rows.map { |r| decode_entity(r) }, count: rows.size }
          rescue Sequel::Error => e
            handle_exception(
              e,
              level:       :error,
              operation:   'apollo.local.graph.find_entities_by_type',
              entity_type: type,
              limit:       limit
            )
            { success: false, error: e.message }
          end

          def find_entities_by_name(name:, limit: 50) # rubocop:disable Metrics/MethodLength
            rows = db[:local_entities].where(name: name.to_s).limit(limit).all
            log.debug { "Apollo::Local::Graph found entities name=#{name} count=#{rows.size}" }
            { success: true, entities: rows.map { |r| decode_entity(r) }, count: rows.size }
          rescue Sequel::Error => e
            handle_exception(
              e,
              level:     :error,
              operation: 'apollo.local.graph.find_entities_by_name',
              name:      name,
              limit:     limit
            )
            { success: false, error: e.message }
          end

          def update_entity(id:, **fields) # rubocop:disable Metrics/MethodLength,Metrics/AbcSize
            now = timestamp
            updates = fields.slice(:entity_type, :name, :domain).transform_values(&:to_s)
            updates[:attributes] = encode(fields[:attributes]) if fields.key?(:attributes)
            updates[:updated_at] = now

            count = db[:local_entities].where(id: id).update(updates)
            return { success: false, error: :not_found } if count.zero?

            log.info { "Apollo::Local::Graph updated entity id=#{id}" }
            { success: true, id: id }
          rescue Sequel::Error => e
            handle_exception(
              e,
              level:     :error,
              operation: 'apollo.local.graph.update_entity',
              entity_id: id,
              fields:    fields.keys
            )
            { success: false, error: e.message }
          end

          def delete_entity(id:)
            result = delete_entity_transaction(id)
            return result unless result[:success]

            log.info { "Apollo::Local::Graph deleted entity id=#{id}" }
            result
          rescue Sequel::Error => e
            handle_exception(e, level: :error, operation: 'apollo.local.graph.delete_entity', entity_id: id)
            { success: false, error: e.message }
          end

          # --- Relationship CRUD ---

          def create_relationship(source_id:, target_id:, relation_type:, attributes: {}) # rubocop:disable Metrics/MethodLength
            normalized_relation_type = normalize_relation_type(relation_type)
            return invalid_relation_type_error(relation_type) unless normalized_relation_type

            existing = existing_relationship(source_id, target_id, normalized_relation_type)
            return deduplicated_relationship(existing) if existing

            id = insert_relationship(source_id, target_id, normalized_relation_type, attributes)
            log.info do
              "Apollo::Local::Graph created relationship id=#{id} source_id=#{source_id} " \
                "target_id=#{target_id} relation_type=#{normalized_relation_type}"
            end
            { success: true, id: id }
          rescue Sequel::UniqueConstraintViolation => e
            duplicate = handle_duplicate_relationship(source_id, target_id, normalized_relation_type)
            return duplicate if duplicate

            handle_exception(
              e,
              level:         :error,
              operation:     'apollo.local.graph.create_relationship',
              source_id:     source_id,
              target_id:     target_id,
              relation_type: normalized_relation_type
            )
            { success: false, error: e.message }
          rescue Sequel::Error => e
            handle_exception(
              e,
              level:         :error,
              operation:     'apollo.local.graph.create_relationship',
              source_id:     source_id,
              target_id:     target_id,
              relation_type: relation_type
            )
            { success: false, error: e.message }
          end

          def find_relationships(entity_id:, relation_type: nil, direction: :outbound) # rubocop:disable Metrics/MethodLength,Metrics/AbcSize
            ds = case direction
                 when :inbound  then db[:local_relationships].where(target_entity_id: entity_id)
                 when :both     then relationship_both_directions(entity_id)
                 else                db[:local_relationships].where(source_entity_id: entity_id)
                 end
            ds = ds.where(relation_type: relation_type.to_s.upcase) if relation_type
            rows = ds.all
            log.debug do
              "Apollo::Local::Graph found relationships entity_id=#{entity_id} direction=#{direction} " \
                "relation_type=#{relation_type || 'any'} count=#{rows.size}"
            end
            { success: true, relationships: rows.map { |r| decode_relationship(r) }, count: rows.size }
          rescue Sequel::Error => e
            handle_exception(
              e,
              level:         :error,
              operation:     'apollo.local.graph.find_relationships',
              entity_id:     entity_id,
              relation_type: relation_type,
              direction:     direction
            )
            { success: false, error: e.message }
          end

          def delete_relationship(id:)
            count = db.transaction { db[:local_relationships].where(id: id).delete }
            return { success: false, error: :not_found } if count.zero?

            log.info { "Apollo::Local::Graph deleted relationship id=#{id}" }
            { success: true, id: id }
          rescue Sequel::Error => e
            handle_exception(e, level: :error, operation: 'apollo.local.graph.delete_relationship', relationship_id: id)
            { success: false, error: e.message }
          end

          # --- Graph Traversal ---

          # Traverse from an entity following edges of the given relation_type.
          # Returns all reachable entities within max_depth hops by expanding one
          # frontier batch per depth level instead of querying neighbors per node.
          #
          # @param entity_id [Integer] starting entity id
          # @param relation_type [String, nil] filter by edge type (nil = any)
          # @param depth [Integer] maximum traversal depth (default 3, max 10)
          # @param direction [Symbol] :outbound (default) or :inbound
          # @return [Hash] { success:, nodes:, edges:, count: }
          def traverse(entity_id:, relation_type: nil, depth: 3, direction: :outbound) # rubocop:disable Metrics/MethodLength,Metrics/AbcSize
            max_depth = [depth.to_i.clamp(1, 10), 10].min
            rel_filter = relation_type&.to_s&.upcase

            visited_ids, edge_rows = run_traversal(entity_id, rel_filter, max_depth, direction)
            entity_rows = visited_ids.empty? ? [] : db[:local_entities].where(id: visited_ids).all

            {
              success: true,
              nodes:   entity_rows.map { |r| decode_entity(r) },
              edges:   edge_rows.map   { |r| decode_relationship(r) },
              count:   entity_rows.size
            }
          rescue Sequel::Error => e
            handle_exception(
              e,
              level:         :error,
              operation:     'apollo.local.graph.traverse',
              entity_id:     entity_id,
              relation_type: relation_type,
              depth:         depth,
              direction:     direction
            )
            { success: false, error: e.message }
          end

          private

          def run_traversal(start_id, rel_filter, max_depth, direction) # rubocop:disable Metrics/MethodLength
            visited   = Set.new([start_id])
            frontier  = [start_id]
            edge_rows = []

            max_depth.times do
              break if frontier.empty?

              rows = fetch_frontier_edges(frontier, rel_filter, direction)
              edge_rows.concat(rows)
              frontier = next_frontier_ids(rows, direction).reject { |neighbor_id| visited.include?(neighbor_id) }.uniq
              frontier.each { |neighbor_id| visited.add(neighbor_id) }
            end

            [visited.to_a, edge_rows.uniq { |r| r[:id] }]
          end

          def fetch_frontier_edges(frontier, rel_filter, direction)
            ds = case direction
                 when :inbound then db[:local_relationships].where(target_entity_id: frontier)
                 else               db[:local_relationships].where(source_entity_id: frontier)
                 end
            ds = ds.where(relation_type: rel_filter) if rel_filter
            ds.all
          end

          def next_frontier_ids(rows, direction)
            rows.map do |row|
              direction == :inbound ? row[:source_entity_id] : row[:target_entity_id]
            end
          end

          def normalize_relation_type(relation_type)
            normalized = relation_type.to_s.upcase
            return normalized if VALID_RELATION_TYPES.include?(normalized)

            nil
          end

          def invalid_relation_type_error(relation_type)
            log.warn { "Apollo::Local::Graph rejected invalid relation_type=#{relation_type}" }
            { success: false, error: :invalid_relation_type }
          end

          def existing_relationship(source_id, target_id, relation_type)
            db[:local_relationships].where(
              source_entity_id: source_id,
              target_entity_id: target_id,
              relation_type:    relation_type
            ).first
          end

          def deduplicated_relationship(existing)
            log.info do
              "Apollo::Local::Graph deduplicated relationship id=#{existing[:id]} " \
                "relation_type=#{existing[:relation_type]}"
            end
            { success: true, id: existing[:id], mode: :deduplicated }
          end

          def insert_relationship(source_id, target_id, relation_type, attributes)
            db.transaction do
              db[:local_relationships].insert(relationship_row(source_id, target_id, relation_type, attributes))
            end
          end

          def relationship_row(source_id, target_id, relation_type, attributes)
            now = timestamp
            {
              source_entity_id: source_id,
              target_entity_id: target_id,
              relation_type:    relation_type,
              attributes:       encode(attributes),
              created_at:       now,
              updated_at:       now
            }
          end

          def handle_duplicate_relationship(source_id, target_id, relation_type)
            existing = existing_relationship(source_id, target_id, relation_type)
            return deduplicated_relationship(existing) if existing

            nil
          end

          def delete_entity_transaction(id)
            result = nil
            db.transaction do
              result = existing_entity?(id) ? delete_existing_entity(id) : missing_entity_result
              raise Sequel::Rollback unless result[:success]
            end
            result
          end

          def existing_entity?(id)
            !db[:local_entities].where(id: id).first.nil?
          end

          def delete_existing_entity(id)
            delete_entity_relationships(id)
            delete_entity_row(id)
            { success: true, id: id }
          end

          def missing_entity_result
            { success: false, error: :not_found }
          end

          def delete_entity_relationships(id)
            db[:local_relationships].where(source_entity_id: id).delete
            db[:local_relationships].where(target_entity_id: id).delete
          end

          def delete_entity_row(id)
            db[:local_entities].where(id: id).delete
          end

          def relationship_both_directions(entity_id)
            src = db[:local_relationships].where(source_entity_id: entity_id)
            tgt = db[:local_relationships].where(target_entity_id: entity_id)
            # Sequel union for SQLite
            src.union(tgt)
          end

          def db
            Legion::Data::Local.connection
          end

          def timestamp
            Time.now.utc.strftime('%Y-%m-%dT%H:%M:%S.%LZ')
          end

          def encode(obj)
            return '{}' if obj.nil? || obj.empty?

            Legion::JSON.dump(obj)
          rescue StandardError => e
            handle_exception(e, level: :debug, operation: 'apollo.local.graph.encode')
            '{}'
          end

          def decode(json_str)
            return {} if json_str.nil? || json_str.strip.empty?

            Legion::JSON.parse(json_str, symbolize_names: true)
          rescue StandardError => e
            handle_exception(e, level: :debug, operation: 'apollo.local.graph.decode')
            {}
          end

          def decode_entity(row)
            {
              id:          row[:id],
              entity_type: row[:entity_type],
              name:        row[:name],
              domain:      row[:domain],
              attributes:  decode(row[:attributes]),
              created_at:  row[:created_at],
              updated_at:  row[:updated_at]
            }
          end

          def decode_relationship(row)
            {
              id:               row[:id],
              source_entity_id: row[:source_entity_id],
              target_entity_id: row[:target_entity_id],
              relation_type:    row[:relation_type],
              attributes:       decode(row[:attributes]),
              created_at:       row[:created_at],
              updated_at:       row[:updated_at]
            }
          end
        end
      end
    end
  end
end
