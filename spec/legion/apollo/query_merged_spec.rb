# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Legion::Apollo, '.query_merged requesting_principal_id forwarding' do
  before do
    allow(described_class).to receive(:started?).and_return(true)
    allow(described_class).to receive(:co_located_reader?).and_return(false)
    allow(described_class).to receive(:transport_available?).and_return(false)
    allow(Legion::Apollo::Local).to receive(:started?).and_return(true)
    allow(Legion::Apollo::Local).to receive(:query).and_return({ success: true, results: [] })
  end

  it 'forwards requesting_principal_id to Apollo::Local.query' do
    described_class.query(text: 'test', scope: :all, requesting_principal_id: 42)
    expect(Legion::Apollo::Local).to have_received(:query).with(
      hash_including(requesting_principal_id: 42)
    )
  end

  it 'forwards nil requesting_principal_id when not provided' do
    described_class.query(text: 'test', scope: :all)
    expect(Legion::Apollo::Local).to have_received(:query).with(
      hash_including(requesting_principal_id: nil)
    )
  end
end
