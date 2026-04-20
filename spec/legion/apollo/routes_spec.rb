# frozen_string_literal: true

require 'spec_helper'

module ApolloRoutesSpecSupport
  class FakeApp
    class << self
      attr_reader :helpers_module

      def helpers(mod)
        @helpers_module = mod
      end

      def get(path, &block)
        routes[:get][path] = block
      end

      def post(path, &block)
        routes[:post][path] = block
      end

      def routes
        @routes ||= { get: {}, post: {} }
      end

      def reset!
        @helpers_module = nil
        @routes = { get: {}, post: {} }
      end
    end
  end

  class FakeHalt < StandardError
    attr_reader :status, :body

    def initialize(status, body)
      @status = status
      @body = body
      super("halt #{status}")
    end
  end

  class FakeContext
    attr_reader :params

    def initialize(app_class:, body: {}, params: {})
      extend app_class.helpers_module if app_class.helpers_module
      @body = body
      @params = params
    end

    def parse_request_body
      @body
    end

    def json_response(payload, status_code: 200)
      { status: status_code, body: payload }
    end

    def json_error(code, message, status_code: 500)
      { error: code, message: message, status_code: status_code }
    end

    def halt(status, body)
      raise FakeHalt.new(status, body)
    end
  end
end

RSpec.describe Legion::Apollo::Routes do
  def call_route(method, path, body: {}, params: {})
    route = ApolloRoutesSpecSupport::FakeApp.routes.fetch(method).fetch(path)
    context = ApolloRoutesSpecSupport::FakeContext.new(
      app_class: ApolloRoutesSpecSupport::FakeApp,
      body:      body,
      params:    params
    )
    context.instance_exec(&route)
  rescue ApolloRoutesSpecSupport::FakeHalt => e
    { status: e.status, body: e.body }
  end

  before do
    ApolloRoutesSpecSupport::FakeApp.reset!
    described_class.registered(ApolloRoutesSpecSupport::FakeApp)
  end

  after { ApolloRoutesSpecSupport::FakeApp.reset! }

  describe 'POST /api/apollo/query' do
    it 'delegates to Legion::Apollo.query and returns 200 on success' do
      allow(Legion::Apollo).to receive(:query).and_return({ success: true, entries: [], count: 0 })

      result = call_route(:post, '/api/apollo/query', body: { query: 'hello', scope: 'all' })

      expect(result[:status]).to eq(200)
      expect(result[:body][:success]).to be true
      expect(Legion::Apollo).to have_received(:query).with(
        hash_including(text: 'hello', scope: :all, limit: 5, min_confidence: nil)
      )
    end

    it 'returns 202 when the library falls back to async transport' do
      allow(Legion::Apollo).to receive(:query).and_return({ success: true, mode: :async })

      result = call_route(:post, '/api/apollo/query', body: { query: 'hello' })

      expect(result[:status]).to eq(202)
      expect(result[:body]).to eq({ success: true, mode: :async })
    end
  end

  describe 'POST /api/apollo/ingest' do
    it 'delegates to Legion::Apollo.ingest and returns 201 on success' do
      allow(Legion::Apollo).to receive(:ingest).and_return({ success: true, mode: :global })

      result = call_route(
        :post,
        '/api/apollo/ingest',
        body: { content: 'hello', tags: ['Team Bond', 'team bond'], scope: 'local' }
      )

      expect(result[:status]).to eq(201)
      expect(result[:body][:success]).to be true
      expect(Legion::Apollo).to have_received(:ingest).with(
        hash_including(content: 'hello', tags: ['team_bond'], scope: :local, source_channel: 'rest_api')
      )
    end

    it 'does not return 201 for failed ingests' do
      allow(Legion::Apollo).to receive(:ingest).and_return({ success: false, error: :no_path_available })

      result = call_route(:post, '/api/apollo/ingest', body: { content: 'hello', tags: ['tag'] })

      expect(result[:status]).to eq(503)
      expect(result[:body]).to eq({ success: false, error: :no_path_available })
    end
  end

  describe 'apollo_status_code mapping' do
    before { described_class.registered(ApolloRoutesSpecSupport::FakeApp) }

    let(:context) do
      ApolloRoutesSpecSupport::FakeContext.new(
        app_class: ApolloRoutesSpecSupport::FakeApp
      )
    end

    it 'returns 503 for :no_path_available' do
      result = { success: false, error: :no_path_available }
      expect(context.send(:apollo_status_code, result)).to eq(503)
    end

    it 'returns 503 for :not_started' do
      result = { success: false, error: :not_started }
      expect(context.send(:apollo_status_code, result)).to eq(503)
    end

    it 'returns 503 for :local_not_started' do
      result = { success: false, error: :local_not_started }
      expect(context.send(:apollo_status_code, result)).to eq(503)
    end

    it 'returns 503 for :upstream_query_failed' do
      result = { success: false, error: :upstream_query_failed }
      expect(context.send(:apollo_status_code, result)).to eq(503)
    end

    it 'returns 503 for :backend_query_failed' do
      result = { success: false, error: :backend_query_failed, detail: 'pgvector syntax error' }
      expect(context.send(:apollo_status_code, result)).to eq(503)
    end

    it 'returns 500 for string error messages (unexpected server failures)' do
      result = { success: false, error: 'unexpected runtime error' }
      expect(context.send(:apollo_status_code, result)).to eq(500)
    end

    it 'returns 200 for success' do
      result = { success: true, entries: [] }
      expect(context.send(:apollo_status_code, result)).to eq(200)
    end

    it 'returns 202 for async mode' do
      result = { success: true, mode: :async }
      expect(context.send(:apollo_status_code, result)).to eq(202)
    end

    it 'returns custom success_status' do
      result = { success: true }
      expect(context.send(:apollo_status_code, result, success_status: 201)).to eq(201)
    end
  end

  describe 'POST /api/apollo/query with backend failure' do
    it 'returns 503 when backend query fails on non-Postgres' do
      allow(Legion::Apollo).to receive(:query).and_return(
        { success: false, error: :backend_query_failed, detail: 'pgvector SQL not supported on SQLite' }
      )

      result = call_route(:post, '/api/apollo/query', body: { query: 'test', scope: 'global' })

      expect(result[:status]).to eq(503)
      expect(result[:body][:error]).to eq(:backend_query_failed)
    end
  end
end
