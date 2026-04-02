# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Legion::Apollo::Settings do
  describe '.default' do
    subject(:defaults) { described_class.default }

    it 'enables apollo by default' do
      expect(defaults[:enabled]).to be true
    end

    it 'includes local settings' do
      expect(defaults[:local]).to be_a(Hash)
    end

    it 'enables local by default' do
      expect(defaults[:local][:enabled]).to be true
    end

    it 'sets retention to 5 years' do
      expect(defaults[:local][:retention_years]).to eq(5)
    end

    it 'defaults query scope to all' do
      expect(defaults[:local][:default_query_scope]).to eq(:all)
    end

    it 'sets fts candidate multiplier to 3' do
      expect(defaults[:local][:fts_candidate_multiplier]).to eq(3)
    end

    it 'sets default limit to 5' do
      expect(defaults[:local][:default_limit]).to eq(5)
    end

    it 'sets min confidence to 0.3' do
      expect(defaults[:local][:min_confidence]).to eq(0.3)
    end

    it 'does not expose unused transport and timeout settings' do
      expect(defaults).not_to have_key(:transport_mode)
      expect(defaults).not_to have_key(:query_timeout)
      expect(defaults).not_to have_key(:ingest_timeout)
    end
  end
end
