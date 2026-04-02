# frozen_string_literal: true

require_relative '../../../lib/legion/apollo/messages/ingest'
require_relative '../../../lib/legion/apollo/messages/query'
require_relative '../../../lib/legion/apollo/messages/writeback'
require_relative '../../../lib/legion/apollo/messages/access_boost'

RSpec.describe 'Legion::Apollo::Messages' do
  shared_examples 'apollo message publisher' do |message_class|
    let(:exchange) { instance_double('Legion::Transport::Exchange', publish: true) }

    before do
      stub_const('Legion::Transport', Module.new)
      stub_const('Legion::Transport::Exchange', Class.new)
      allow(Legion::Transport::Exchange).to receive(:new).and_return(exchange)
    end

    it 'publishes using the Apollo exchange and routing key' do
      message_class.new.publish('{"ok":true}')

      expect(Legion::Transport::Exchange).to have_received(:new).with(
        message_class::EXCHANGE,
        type:        :topic,
        auto_delete: false
      )
      expect(exchange).to have_received(:publish).with(
        '{"ok":true}',
        routing_key: message_class::ROUTING_KEY
      )
    end
  end

  describe Legion::Apollo::Messages::Ingest do
    it 'has correct routing key' do
      expect(described_class::ROUTING_KEY).to eq('apollo.ingest')
    end

    it 'has correct exchange' do
      expect(described_class::EXCHANGE).to eq('apollo')
    end

    it 'does not fail when transport is not available' do
      expect { described_class.new.publish('{}') }.not_to raise_error
    end

    include_examples 'apollo message publisher', described_class
  end

  describe Legion::Apollo::Messages::Query do
    it 'has correct routing key' do
      expect(described_class::ROUTING_KEY).to eq('apollo.query')
    end

    include_examples 'apollo message publisher', described_class
  end

  describe Legion::Apollo::Messages::Writeback do
    it 'has correct routing key' do
      expect(described_class::ROUTING_KEY).to eq('apollo.writeback')
    end

    include_examples 'apollo message publisher', described_class
  end

  describe Legion::Apollo::Messages::AccessBoost do
    it 'has correct routing key' do
      expect(described_class::ROUTING_KEY).to eq('apollo.access.boost')
    end

    include_examples 'apollo message publisher', described_class
  end
end
