# frozen_string_literal: true

require 'legion/logging'

module Legion
  module Apollo
    module Messages
      # Envelope for publishing knowledge query requests to the Apollo exchange.
      class Query
        include Legion::Logging::Helper

        ROUTING_KEY = 'apollo.query'
        EXCHANGE    = 'apollo'

        def publish(payload)
          unless defined?(Legion::Transport)
            log.warn 'Apollo::Messages::Query publish skipped because Legion::Transport is unavailable'
            return
          end

          exchange = Legion::Transport::Exchange.new(EXCHANGE, type: :topic, auto_delete: false)
          exchange.publish(payload, routing_key: ROUTING_KEY)
          log.info { "Apollo::Messages::Query published routing_key=#{ROUTING_KEY} payload_bytes=#{payload.to_s.bytesize}" }
        end
      end
    end
  end
end
