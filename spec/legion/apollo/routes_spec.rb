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
        hash_including(text: 'hello', scope: :all, limit: 5, min_confidence: 0.3)
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
end
