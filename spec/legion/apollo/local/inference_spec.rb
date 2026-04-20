# frozen_string_literal: true

require 'spec_helper'
require 'sequel'
require 'sequel/extensions/migration'

RSpec.describe 'Apollo::Local inference tagging' do
  let(:db) { Sequel.sqlite }

  before do
    Legion::Apollo::Local.shutdown if Legion::Apollo::Local.started?

    local_db = db
    migration_path = File.expand_path('../../../../lib/legion/apollo/local/migrations', __dir__)
    Sequel::Migrator.run(local_db, migration_path, table: :schema_migrations_apollo_local)

    stub_const('Legion::Data::Local', Module.new do
      extend self

      define_method(:connected?) { true }
      define_method(:connection) { local_db }
      define_method(:register_migrations) { |**_| nil }
    end)

    Legion::Apollo::Local.start
  end

  after { Legion::Apollo::Local.shutdown }

  it 'stores is_inference flag on ingest' do
    Legion::Apollo::Local.ingest(content: 'LLM synthesized fact', tags: %w[ai], is_inference: true)
    row = db[:local_knowledge].where(content: 'LLM synthesized fact').first
    expect(row[:is_inference]).to be_truthy
  end

  it 'defaults is_inference to false' do
    Legion::Apollo::Local.ingest(content: 'Extracted fact from doc', tags: %w[doc])
    row = db[:local_knowledge].where(content: 'Extracted fact from doc').first
    expect(row[:is_inference]).to be_falsey
  end

  it 'uses INITIAL_INFERENCE_CONFIDENCE when is_inference and no explicit confidence' do
    Legion::Apollo::Local.ingest(content: 'Inferred knowledge', tags: %w[ai], is_inference: true)
    row = db[:local_knowledge].where(content: 'Inferred knowledge').first
    expect(row[:confidence]).to eq(Legion::Apollo::Helpers::Confidence::INITIAL_INFERENCE_CONFIDENCE)
  end

  it 'respects explicit confidence even for inferences' do
    Legion::Apollo::Local.ingest(content: 'High confidence inference', tags: %w[ai], is_inference: true,
                                 confidence: 0.8)
    row = db[:local_knowledge].where(content: 'High confidence inference').first
    expect(row[:confidence]).to eq(0.8)
  end

  it 'query includes inferences by default' do
    Legion::Apollo::Local.ingest(content: 'Extracted: Ruby is great', tags: %w[lang])
    Legion::Apollo::Local.ingest(content: 'Inferred: Ruby community is strong', tags: %w[lang], is_inference: true)
    result = Legion::Apollo::Local.query(text: 'Ruby', tags: %w[lang])
    expect(result[:results].size).to eq(2)
  end

  it 'query filters out inferences when include_inferences: false' do
    Legion::Apollo::Local.ingest(content: 'Extracted: Python is popular', tags: %w[lang])
    Legion::Apollo::Local.ingest(content: 'Inferred: Python will dominate', tags: %w[lang], is_inference: true)
    result = Legion::Apollo::Local.query(text: 'Python', tags: %w[lang], include_inferences: false)
    contents = result[:results].map { |r| r[:content] }
    expect(contents).to include('Extracted: Python is popular')
    expect(contents).not_to include('Inferred: Python will dominate')
  end
end
