# frozen_string_literal: true

require 'spec_helper'
require 'sequel'

RSpec.describe Legion::Apollo::Local, '.seed_self_knowledge' do
  let(:local_db) { Sequel.sqlite }

  before do
    described_class.reset!

    local_db.create_table(:local_knowledge) do
      primary_key :id
      String :content
      String :content_hash
      String :tags
      String :embedding
      String :embedded_at
      String :source_channel
      String :source_agent
      String :submitted_by
      Float :confidence
      String :expires_at
      String :created_at
      String :updated_at
    end

    local_db.run('CREATE VIRTUAL TABLE IF NOT EXISTS local_knowledge_fts USING fts5(content, tags)')

    db_ref = local_db
    stub_const('Legion::Data::Local', Module.new do
      extend self

      define_method(:connected?) { true }
      define_method(:connection) { db_ref }
      define_method(:register_migrations) { |**_| nil }
    end)

    described_class.start
  end

  after { described_class.reset! }

  context 'with real self-knowledge files' do
    it 'ingests markdown files from data/self-knowledge' do
      described_class.seed_self_knowledge
      expect(described_class.seeded?).to be true
      expect(local_db[:local_knowledge].count).to be > 0
    end

    it 'tags entries with legionio and self-knowledge' do
      described_class.seed_self_knowledge
      row = local_db[:local_knowledge].first
      tags = Legion::JSON.parse(row[:tags])
      expect(tags).to include('legionio', 'self-knowledge')
    end

    it 'includes the filename as a tag' do
      described_class.seed_self_knowledge
      all_tags = local_db[:local_knowledge].all.flat_map { |r| Legion::JSON.parse(r[:tags]) }
      expect(all_tags).to include('01-what-is-legion')
    end

    it 'sets source_channel to self-knowledge' do
      described_class.seed_self_knowledge
      row = local_db[:local_knowledge].first
      expect(row[:source_channel]).to eq('self-knowledge')
    end

    it 'sets submitted_by to legion-apollo' do
      described_class.seed_self_knowledge
      row = local_db[:local_knowledge].first
      expect(row[:submitted_by]).to eq('legion-apollo')
    end

    it 'sets confidence to 0.9' do
      described_class.seed_self_knowledge
      row = local_db[:local_knowledge].first
      expect(row[:confidence]).to eq(0.9)
    end
  end

  context 'idempotency' do
    it 'does not re-seed on second call' do
      described_class.seed_self_knowledge
      count_after_first = local_db[:local_knowledge].count

      described_class.seed_self_knowledge
      expect(local_db[:local_knowledge].count).to eq(count_after_first)
    end

    it 'serializes concurrent seed requests' do
      allow(described_class).to receive(:self_knowledge_files).and_return(['seed.md'])
      allow(described_class).to receive(:seed_files) do |_files|
        sleep 0.05
        1
      end

      threads = Array.new(2) { Thread.new { described_class.seed_self_knowledge } }
      threads.each(&:join)

      expect(described_class).to have_received(:seed_files).once
      expect(described_class.seeded?).to be true
    end

    it 'deduplicates content by hash' do
      described_class.seed_self_knowledge
      count = local_db[:local_knowledge].count

      described_class.instance_variable_set(:@seeded, false)
      described_class.seed_self_knowledge
      expect(local_db[:local_knowledge].count).to eq(count)
    end
  end

  context 'when not started' do
    it 'does nothing' do
      described_class.shutdown
      described_class.seed_self_knowledge
      expect(described_class.seeded?).to be false
    end
  end

  context 'when already seeded' do
    it 'skips immediately' do
      described_class.seed_self_knowledge
      expect(described_class.seeded?).to be true

      allow(described_class).to receive(:self_knowledge_files).and_call_original
      described_class.seed_self_knowledge
      expect(described_class).not_to have_received(:self_knowledge_files)
    end
  end

  context 'when seed directory is missing' do
    it 'marks as not seeded and returns nil' do
      allow(File).to receive(:directory?).and_call_original
      allow(File).to receive(:directory?).with(a_string_including('self-knowledge')).and_return(false)
      described_class.seed_self_knowledge
      expect(described_class.seeded?).to be false
    end
  end

  context 'global ingestion' do
    it 'ingests globally when Apollo is available' do
      allow(Legion::Apollo).to receive(:started?).and_return(true)
      allow(Legion::Apollo).to receive(:respond_to?).and_call_original
      allow(Legion::Apollo).to receive(:respond_to?).with(:ingest).and_return(true)
      allow(Legion::Apollo).to receive(:ingest).and_return({ success: true })

      described_class.seed_self_knowledge
      expect(Legion::Apollo).to have_received(:ingest).at_least(:once)
    end
  end
end
