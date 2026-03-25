# frozen_string_literal: true

require_relative '../../../../lib/legion/apollo/helpers/tag_normalizer'

RSpec.describe Legion::Apollo::Helpers::TagNormalizer do
  describe '.normalize' do
    it 'downcases and deduplicates' do
      expect(described_class.normalize(%w[Foo foo BAR])).to eq(%w[foo bar])
    end

    it 'strips invalid characters' do
      expect(described_class.normalize(['hello world!'])).to eq(%w[hello_world_])
    end

    it 'limits to MAX_TAGS' do
      tags = (1..30).map { |i| "tag#{i}" }
      expect(described_class.normalize(tags).size).to eq(20)
    end

    it 'handles nil and empty' do
      expect(described_class.normalize(nil)).to eq([])
      expect(described_class.normalize([])).to eq([])
    end
  end
end
