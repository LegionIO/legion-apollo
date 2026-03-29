# legion-apollo Agent Notes

## Scope

`legion-apollo` is the shared Apollo client gem. It exposes `query`, `ingest`, and `retrieve` with scope routing (`:global`, `:local`, `:all`) and includes the node-local `Apollo::Local` store.

## Fast Start

```bash
bundle install
bundle exec rspec
bundle exec rubocop
```

## Primary Entry Points

- `lib/legion/apollo.rb`
- `lib/legion/apollo/local.rb`
- `lib/legion/apollo/settings.rb`
- `lib/legion/apollo/messages/`
- `lib/legion/apollo/helpers/`
- `lib/legion/apollo/local/migrations/`

## Guardrails

- Keep routing semantics stable:
  `:global` for remote path, `:local` for local SQLite, `:all` for merged/deduped results.
- Global store logic in this gem is client-side only; avoid embedding server-side Apollo DB behavior here.
- `Apollo::Local` is the only DB-touching path and must remain guarded on `Data::Local` availability.
- Preserve content-hash dedup, confidence ranking, and local retention behavior.
- Optional integrations (`legion-data`, `legion-transport`, `legion-llm`) must stay behind `defined?` guards.

## Validation

- Run specs for route and local-store behavior.
- Before handoff, run full `bundle exec rspec` and `bundle exec rubocop`.
