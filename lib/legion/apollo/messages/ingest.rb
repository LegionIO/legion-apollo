# frozen_string_literal: true

require 'legion/logging'

module Legion
  module Apollo
    module Messages
      # Envelope for publishing knowledge ingest requests to the Apollo exchange.
      class Ingest
        include Legion::Logging::Helper

        ROUTING_KEY = 'apollo.ingest'
        EXCHANGE    = 'apollo'

        def publish(payload)
          unless defined?(Legion::Transport)
            log.warn 'Apollo::Messages::Ingest publish skipped because Legion::Transport is unavailable'
            return
          end

          exchange = Legion::Transport::Exchange.new(EXCHANGE, type: :topic, auto_delete: false)
          exchange.publish(payload, routing_key: ROUTING_KEY)
          log.info { "Apollo::Messages::Ingest published routing_key=#{ROUTING_KEY} payload_bytes=#{payload.to_s.bytesize}" }
        end
      end
    end
  end
end
