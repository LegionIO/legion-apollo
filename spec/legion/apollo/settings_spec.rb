# frozen_string_literal: true

RSpec.describe Legion::Apollo::Settings do
  describe '.default' do
    it 'returns a hash with required keys' do
      defaults = described_class.default
      expect(defaults).to be_a(Hash)
      expect(defaults[:enabled]).to be true
      expect(defaults[:default_limit]).to eq(5)
      expect(defaults[:min_confidence]).to eq(0.3)
      expect(defaults[:max_tags]).to eq(20)
    end
  end
end
