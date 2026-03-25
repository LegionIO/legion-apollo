# frozen_string_literal: true

require_relative '../../../../lib/legion/apollo/helpers/confidence'

RSpec.describe Legion::Apollo::Helpers::Confidence do
  it 'validates statuses' do
    expect(described_class.valid_status?(:confirmed)).to be true
    expect(described_class.valid_status?(:invalid)).to be false
  end

  it 'validates content types' do
    expect(described_class.valid_content_type?(:fact)).to be true
    expect(described_class.valid_content_type?(:invalid)).to be false
  end

  it 'checks write gate' do
    expect(described_class.above_write_gate?(0.5)).to be true
    expect(described_class.above_write_gate?(0.2)).to be false
  end

  it 'checks high confidence' do
    expect(described_class.high_confidence?(0.9)).to be true
    expect(described_class.high_confidence?(0.5)).to be false
  end
end
