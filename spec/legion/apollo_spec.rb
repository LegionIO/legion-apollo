# frozen_string_literal: true

require 'sequel'
require 'sequel/extensions/migration'

RSpec.describe Legion::Apollo do
  describe '.start' do
    it 'sets started? to true' do
      described_class.start
      expect(described_class.started?).to be true
    end

    it 'is idempotent' do
      described_class.start
      described_class.start
      expect(described_class.started?).to be true
    end

    it 'does not start when apollo.enabled is false' do
      Legion::Settings[:apollo][:enabled] = false

      described_class.start

      expect(described_class.started?).to be false
    end

    it 'starts the local store before Apollo reports started' do
      allow(Legion::Apollo::Local).to receive(:start) do
        expect(described_class.started?).to be false
      end
      allow(Legion::Apollo::Local).to receive(:started?).and_return(false)

      described_class.start

      expect(described_class.started?).to be true
    end

    it 'serializes concurrent start calls' do
      allow(Legion::Apollo::Local).to receive(:start) do
        sleep 0.05
      end
      allow(Legion::Apollo::Local).to receive(:started?).and_return(false)

      threads = Array.new(2) { Thread.new { described_class.start } }
      threads.each(&:join)

      expect(Legion::Apollo::Local).to have_received(:start).once
      expect(described_class.started?).to be true
    end
  end

  describe '.shutdown' do
    it 'sets started? to false' do
      described_class.start
      described_class.shutdown
      expect(described_class.started?).to be false
    end

    it 'shuts down the local store when it is running' do
      db = Sequel.sqlite

      stub_const('Legion::Data::Local', Module.new do
        extend self

        define_method(:connected?) { true }
        define_method(:connection) { db }
        define_method(:register_migrations) { |**_| nil }
      end)
      Sequel::Migrator.run(db, Legion::Apollo::Local::MIGRATION_PATH)

      described_class.start
      expect(Legion::Apollo::Local.started?).to be true

      described_class.shutdown

      expect(described_class.started?).to be false
      expect(Legion::Apollo::Local.started?).to be false
    end
  end

  describe '.query' do
    context 'when not started' do
      it 'returns not_started error' do
        result = described_class.query(text: 'test')
        expect(result).to eq({ success: false, error: :not_started })
      end
    end

    context 'when started but no transport or data' do
      before { described_class.start }

      it 'returns no_path_available' do
        result = described_class.query(text: 'test')
        expect(result).to eq({ success: false, error: :no_path_available })
      end
    end

    context 'when started and a co-located reader is available' do
      let(:knowledge_runner) do
        Module.new do
          def self.handle_query(**); end
        end
      end

      before do
        described_class.start
        allow(described_class).to receive(:co_located_reader?).and_return(true)
        stub_const('Legion::Extensions', Module.new)
        stub_const('Legion::Extensions::Apollo', Module.new)
        stub_const('Legion::Extensions::Apollo::Runners', Module.new)
        stub_const('Legion::Extensions::Apollo::Runners::Knowledge', knowledge_runner)
        allow(knowledge_runner).to receive(:handle_query).and_return(
          { success: true, entries: [], count: 0 }
        )
      end

      it 'normalizes text into query for the co-located runner' do
        described_class.query(text: 'test')

        expect(knowledge_runner).to have_received(:handle_query).with(
          hash_including(text: 'test', query: 'test')
        )
      end

      it 'flattens structured text blocks before querying' do
        described_class.query(text: [{ type: 'text', text: 'what tools are available to you?' }])

        expect(knowledge_runner).to have_received(:handle_query).with(
          hash_including(
            text:  'what tools are available to you?',
            query: 'what tools are available to you?'
          )
        )
      end

      it 'strips null bytes before querying' do
        described_class.query(text: "hello\u0000world")

        expect(knowledge_runner).to have_received(:handle_query).with(
          hash_including(text: 'helloworld', query: 'helloworld')
        )
      end
    end
  end

  describe '.ingest' do
    context 'when not started' do
      it 'returns not_started error' do
        result = described_class.ingest(content: 'test', tags: %w[test])
        expect(result).to eq({ success: false, error: :not_started })
      end
    end

    context 'when started but no transport or data' do
      before { described_class.start }

      it 'returns no_path_available' do
        result = described_class.ingest(content: 'test')
        expect(result).to eq({ success: false, error: :no_path_available })
      end
    end

    context 'when started and a co-located writer is available' do
      let(:knowledge_runner) do
        Module.new do
          def self.handle_ingest(**); end
        end
      end

      before do
        described_class.start
        allow(described_class).to receive(:co_located_writer?).and_return(true)
        stub_const('Legion::Extensions', Module.new)
        stub_const('Legion::Extensions::Apollo', Module.new)
        stub_const('Legion::Extensions::Apollo::Runners', Module.new)
        stub_const('Legion::Extensions::Apollo::Runners::Knowledge', knowledge_runner)
        allow(knowledge_runner).to receive(:handle_ingest).and_return({ success: true })
      end

      it 'strips null bytes from indexed and raw content before routing' do
        described_class.ingest(content: "indexed\u0000text", raw_content: "raw\u0000text")

        expect(knowledge_runner).to have_received(:handle_ingest).with(
          hash_including(content: 'indexedtext', raw_content: 'rawtext')
        )
      end
    end
  end

  describe '.retrieve' do
    it 'delegates to query' do
      described_class.start
      result = described_class.retrieve(text: 'test', limit: 3)
      expect(result).to eq({ success: false, error: :no_path_available })
    end
  end

  describe '.transport_available?' do
    it 'returns false by default' do
      described_class.start
      expect(described_class.transport_available?).to be false
    end

    it 'returns true when transport is connected' do
      Legion::Settings[:transport] = { connected: true }
      stub_const('Legion::Transport', Module.new)
      described_class.start
      expect(described_class.transport_available?).to be true
    end
  end

  describe '.data_available?' do
    it 'returns false by default' do
      described_class.start
      expect(described_class.data_available?).to be false
    end

    it 'returns true when data is connected' do
      Legion::Settings[:data] = { connected: true }
      stub_const('Legion::Data', Module.new)
      described_class.start
      expect(described_class.data_available?).to be true
    end
  end

  describe 'register_routes (called during .start)' do
    context 'when Legion::API is available and responds to register_library_routes' do
      let(:fake_api) do
        Module.new do
          def self.register_library_routes(_name, _mod); end
        end
      end

      it 'calls register_library_routes with apollo and Routes module' do
        stub_const('Legion::API', fake_api)
        expect(Legion::API).to receive(:register_library_routes).with('apollo', Legion::Apollo::Routes)
        described_class.start
      end
    end

    context 'when Legion::API is not defined' do
      it 'does not raise and completes start normally' do
        expect { described_class.start }.not_to raise_error
        expect(described_class.started?).to be true
      end
    end
  end
end
