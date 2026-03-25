# frozen_string_literal: true

require_relative '../../../../lib/legion/apollo/helpers/similarity'

RSpec.describe Legion::Apollo::Helpers::Similarity do
  describe '.cosine_similarity' do
    it 'returns 1.0 for identical vectors' do
      vec = [1.0, 0.0, 1.0]
      expect(described_class.cosine_similarity(vec, vec)).to be_within(0.001).of(1.0)
    end

    it 'returns 0.0 for orthogonal vectors' do
      expect(described_class.cosine_similarity([1, 0], [0, 1])).to be_within(0.001).of(0.0)
    end

    it 'returns 0.0 for nil or empty' do
      expect(described_class.cosine_similarity(nil, [1])).to eq(0.0)
      expect(described_class.cosine_similarity([], [])).to eq(0.0)
    end

    it 'returns 0.0 for mismatched dimensions' do
      expect(described_class.cosine_similarity([1, 2], [1, 2, 3])).to eq(0.0)
    end
  end

  describe '.classify_match' do
    it 'classifies exact match' do
      expect(described_class.classify_match(0.96)).to eq(:exact)
    end

    it 'classifies high similarity' do
      expect(described_class.classify_match(0.90)).to eq(:high)
    end

    it 'classifies corroboration' do
      expect(described_class.classify_match(0.80)).to eq(:corroboration)
    end

    it 'classifies related' do
      expect(described_class.classify_match(0.60)).to eq(:related)
    end

    it 'classifies unrelated' do
      expect(described_class.classify_match(0.30)).to eq(:unrelated)
    end
  end
end
