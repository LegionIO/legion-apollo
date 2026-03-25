# legion-apollo

Apollo client library for the LegionIO framework.

Provides `query`, `ingest`, and `retrieve` with smart routing: co-located lex-apollo service, RabbitMQ transport, or graceful failure.

## Usage

```ruby
Legion::Apollo.start

Legion::Apollo.ingest(content: 'Some knowledge', tags: %w[fact ruby])
results = Legion::Apollo.query(text: 'tell me about ruby', limit: 5)
```

## License

Apache-2.0
