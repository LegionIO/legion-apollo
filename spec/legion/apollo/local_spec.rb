# frozen_string_literal: true

require 'spec_helper'
require 'sequel'

RSpec.describe Legion::Apollo::Local do
  before do
    described_class.shutdown if described_class.started?
  end

  describe '.start / .shutdown / .started?' do
    it 'is not started by default' do
      expect(described_class.started?).to be false
    end

    context 'when Data::Local is available' do
      let(:db) { Sequel.sqlite }

      before do
        stub_const('Legion::Data::Local', Module.new do
          extend self

          define_method(:connected?) { true }
          define_method(:connection) { db }
          define_method(:register_migrations) { |**_| nil }
        end)
        allow(Legion::Data::Local).to receive(:register_migrations)
      end

      it 'starts and registers migrations' do
        described_class.start
        expect(described_class.started?).to be true
        expect(Legion::Data::Local).to have_received(:register_migrations).with(
          name: :apollo_local, path: anything
        )
      end

      it 'shuts down cleanly' do
        described_class.start
        described_class.shutdown
        expect(described_class.started?).to be false
      end
    end

    context 'when Data::Local is not available' do
      it 'does not start' do
        described_class.start
        expect(described_class.started?).to be false
      end
    end

    context 'when disabled in settings' do
      before do
        Legion::Settings[:apollo][:local][:enabled] = false
      end

      it 'does not start' do
        described_class.start
        expect(described_class.started?).to be false
      end
    end
  end
end
