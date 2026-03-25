# frozen_string_literal: true

module Legion
  module Apollo
    module Messages
      # Envelope for publishing knowledge writeback events to the Apollo exchange.
      class Writeback
        ROUTING_KEY = 'apollo.writeback'
        EXCHANGE    = 'apollo'

        def publish(payload)
          return unless defined?(Legion::Transport)

          exchange = Legion::Transport::Exchange.new(EXCHANGE, type: :topic, auto_delete: false)
          exchange.publish(payload, routing_key: ROUTING_KEY)
        end
      end
    end
  end
end
