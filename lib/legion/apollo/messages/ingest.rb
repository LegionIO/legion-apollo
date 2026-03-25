# frozen_string_literal: true

module Legion
  module Apollo
    module Messages
      # Envelope for publishing knowledge ingest requests to the Apollo exchange.
      class Ingest
        ROUTING_KEY = 'apollo.ingest'
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
