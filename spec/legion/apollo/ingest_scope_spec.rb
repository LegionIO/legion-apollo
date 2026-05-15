# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Legion::Apollo do
  before { described_class.start }

  describe '.ingest with scope: :local' do
    context 'when Local is started' do
      before do
        allow(Legion::Apollo::Local).to receive(:started?).and_return(true)
        allow(Legion::Apollo::Local).to receive(:ingest).and_return({ success: true, mode: :local, id: 42 })
      end

      it 'delegates to Local' do
        result = described_class.ingest(content: 'test fact', tags: %w[test], scope: :local)
        expect(result[:success]).to be true
        expect(result[:mode]).to eq(:local)
        expect(Legion::Apollo::Local).to have_received(:ingest).with(hash_including(content: 'test fact'))
      end

      it 'normalizes tags before delegating to Local' do
        described_class.ingest(content: 'test fact', tags: ['Team Bond', 'team bond'], scope: :local)

        expect(Legion::Apollo::Local).to have_received(:ingest).with(
          hash_including(tags: ['team_bond'])
        )
      end
    end

    context 'when Local is not started' do
      it 'returns no_path_available' do
        result = described_class.ingest(content: 'test', scope: :local)
        expect(result).to eq({ success: false, error: :no_path_available })
      end
    end
  end

  describe '.ingest with scope: :all' do
    context 'when only local is started' do
      before do
        allow(Legion::Apollo::Local).to receive(:started?).and_return(true)
        allow(Legion::Apollo::Local).to receive(:ingest).and_return({ success: true, mode: :local, id: 1 })
      end

      it 'writes to local and returns success' do
        result = described_class.ingest(content: 'fact', tags: [], scope: :all)
        expect(result[:success]).to be true
        expect(Legion::Apollo::Local).to have_received(:ingest)
      end
    end
  end

  describe '.ingest identity injection' do
    context 'when Identity::Process is defined and resolved' do
      before do
        stub_const('Legion::Identity::Process', Module.new do
          extend self

          define_method(:identity_hash) do
            { canonical_name: 'alice', db_principal_id: 42, db_identity_id: 99 }
          end
        end)
        allow(Legion::Apollo::Local).to receive(:started?).and_return(true)
        allow(Legion::Apollo::Local).to receive(:ingest).and_return({ success: true, mode: :local, id: 1 })
      end

      it 'injects identity_canonical_name into the payload' do
        described_class.ingest(content: 'test', tags: [], scope: :local)
        expect(Legion::Apollo::Local).to have_received(:ingest).with(
          hash_including(identity_canonical_name: 'alice')
        )
      end

      it 'injects identity_principal_id into the payload' do
        described_class.ingest(content: 'test', tags: [], scope: :local)
        expect(Legion::Apollo::Local).to have_received(:ingest).with(
          hash_including(identity_principal_id: 42)
        )
      end

      it 'defaults access_scope to global' do
        described_class.ingest(content: 'test', tags: [], scope: :local)
        expect(Legion::Apollo::Local).to have_received(:ingest).with(
          hash_including(access_scope: 'global')
        )
      end

      it 'respects explicit access_scope override' do
        described_class.ingest(content: 'test', tags: [], scope: :local, access_scope: 'private')
        expect(Legion::Apollo::Local).to have_received(:ingest).with(
          hash_including(access_scope: 'private')
        )
      end
    end

    context 'when Identity::Process is not defined' do
      before do
        hide_const('Legion::Identity::Process') if defined?(Legion::Identity::Process)
        allow(Legion::Apollo::Local).to receive(:started?).and_return(true)
        allow(Legion::Apollo::Local).to receive(:ingest).and_return({ success: true, mode: :local, id: 1 })
      end

      it 'still ingests successfully with access_scope: global' do
        result = described_class.ingest(content: 'test', tags: [], scope: :local)
        expect(result[:success]).to be true
        expect(Legion::Apollo::Local).to have_received(:ingest).with(
          hash_including(access_scope: 'global')
        )
      end
    end
  end
end
