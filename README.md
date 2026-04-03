# kemal-cache

[![CI](https://github.com/kemalcr/kemal-cache/actions/workflows/ci.yml/badge.svg)](https://github.com/kemalcr/kemal-cache/actions/workflows/ci.yml)

## Powerful Caching For Kemal Applications

`kemal-cache` is production-oriented response caching middleware for [Kemal](https://kemalcr.com/).
It is built for teams that want lower response times, less repeated work, and safer HTTP caching behavior without bolting on a large framework.

Use it when your application serves expensive pages, API responses, catalog endpoints, content feeds, or read-heavy routes that should be fast on repeat requests.

## Why `kemal-cache`

- Kemal-native middleware with a clean Crystal API
- safe-by-default behavior for authenticated, cookie-bearing, and private responses
- in-memory and Redis-backed stores
- custom cache keys, filters, invalidation, and TTL policies
- automatic `ETag` and `Last-Modified` generation
- conditional request support with `304 Not Modified`
- built-in counters and event hooks for observability
- focused surface area that stays easy to reason about

## What You Get

`kemal-cache` is designed to cover the caching capabilities most Kemal apps actually need:

- route-level response caching with minimal setup
- storage-agnostic design via `Store`
- strong default rules around what should not be cached
- request-aware cache keys
- explicit invalidation APIs
- safe fallback behavior when cached payloads are corrupt
- deployment flexibility from single-process apps to multi-instance Redis-backed setups

## Quick Start

Add the shard to `shard.yml`:

```yaml
dependencies:
  kemal-cache:
    github: kemalcr/kemal-cache
```

Install dependencies:

```bash
shards install
```

Then add the middleware:

```crystal
require "kemal-cache"

use Kemal::Cache::Handler.new

get "/articles" do
  "Expensive response"
end

Kemal.run
```

Every response will include `X-Kemal-Cache: MISS` or `X-Kemal-Cache: HIT`, so cache behavior is visible immediately during development and debugging.

## Out-Of-The-Box Behavior

Without any configuration, `kemal-cache`:

- caches `GET` requests only
- uses `context.request.resource` as the cache key
- caches successful `2xx` responses only
- stores entries for `10.minutes`
- uses `Kemal::Cache::MemoryStore`
- bypasses requests with `Authorization` or `Cookie`
- skips storing responses with `Set-Cookie`
- skips storing responses with `Cache-Control: no-store`, `no-cache`, or `private`
- skips storing responses with `Vary: *`
- skips storing responses larger than `1_048_576` bytes
- skips storing responses that call `flush`
- auto-generates `ETag` and `Last-Modified`
- returns `304 Not Modified` for matching conditional requests

Those defaults are intentionally conservative so the middleware is useful in production without forcing you to hand-audit every route first.

## Installation Notes

`require "kemal-cache"` loads the core middleware and `MemoryStore`.

If you want Redis support, add `redis` to your application and require the Redis entrypoint explicitly:

```yaml
dependencies:
  kemal-cache:
    github: kemalcr/kemal-cache
  redis:
    github: jgaskins/redis
```

```crystal
require "kemal-cache/redis"
```

This keeps the base package lean for applications that only need in-process caching.

## Common Use Cases

### Cache expensive HTML pages

```crystal
require "kemal-cache"

use Kemal::Cache::Handler.new

get "/pricing" do
  render "src/views/pricing.ecr"
end
```

### Cache API responses with a custom TTL

```crystal
config = Kemal::Cache::Config.new(
  expires_in: 2.minutes
)

use Kemal::Cache::Handler.new(config)

get "/api/products" do
  ProductSerializer.render(ProductQuery.latest)
end
```

### Share cache across multiple app instances with Redis

```crystal
require "kemal-cache/redis"

store = Kemal::Cache::RedisStore.from_env("REDIS_URL", namespace: "shop-api-cache")
config = Kemal::Cache::Config.new(store: store)

use Kemal::Cache::Handler.new(config)
```

## Configuration

Create a custom `Kemal::Cache::Config` when you want to tune behavior:

```crystal
require "kemal-cache"

config = Kemal::Cache::Config.new(
  expires_in: 2.minutes,
  cacheable_methods: ["GET"],
  cacheable_status_codes: [200, 202],
  max_body_bytes: 128_000,
  cache_streaming: false,
  auto_etag: true,
  auto_last_modified: true,
  conditional_get: true,
  skip_if: ->(context : HTTP::Server::Context) { context.request.path.starts_with?("/admin") },
  should_cache: ->(context : HTTP::Server::Context) { context.response.status_code == 202 }
)

use Kemal::Cache::Handler.new(config)
```

### Cache Keys

By default the key is `context.request.resource`, which includes the path and query string.

Override it with `key_generator` when you need to change cache granularity:

```crystal
config = Kemal::Cache::Config.new(
  key_generator: ->(context : HTTP::Server::Context) do
    locale = context.request.headers["Accept-Language"]? || "default"
    "#{context.request.path}:#{locale}"
  end
)
```

### Methods And Status Codes

Opt in to additional HTTP methods:

```crystal
config = Kemal::Cache::Config.new(
  cacheable_methods: ["GET", "POST"]
)
```

Restrict or broaden the status-code policy:

```crystal
config = Kemal::Cache::Config.new(
  cacheable_status_codes: [200, 203, 301]
)
```

Pass `nil` to cache every response status code:

```crystal
config = Kemal::Cache::Config.new(
  cacheable_status_codes: nil
)
```

### Request And Response Filters

Use `skip_if` to bypass both lookup and storage:

```crystal
config = Kemal::Cache::Config.new(
  skip_if: ->(context : HTTP::Server::Context) do
    context.request.query_params["preview"]? == "true"
  end
)
```

Use `should_cache` for the final storage decision after the response is built:

```crystal
config = Kemal::Cache::Config.new(
  should_cache: ->(context : HTTP::Server::Context) do
    context.response.status_code == 202
  end
)
```

Temporarily disable caching without removing the middleware:

```crystal
config = Kemal::Cache::Config.new(enabled: false)
```

### Response Size And Streaming Guards

Adjust the body size limit:

```crystal
config = Kemal::Cache::Config.new(
  max_body_bytes: 128_000
)
```

Disable the body size limit entirely:

```crystal
config = Kemal::Cache::Config.new(
  max_body_bytes: nil
)
```

Allow caching responses that call `flush`:

```crystal
config = Kemal::Cache::Config.new(
  cache_streaming: true
)
```

### HTTP Validators

Validator support is enabled by default:

```crystal
config = Kemal::Cache::Config.new(
  auto_etag: true,
  auto_last_modified: true,
  conditional_get: true
)
```

If your application already manages validator headers, `kemal-cache` preserves them.

You can disable automatic validators or conditional handling:

```crystal
config = Kemal::Cache::Config.new(
  auto_etag: false,
  auto_last_modified: false,
  conditional_get: false
)
```

## Stores

### `MemoryStore`

`Kemal::Cache::MemoryStore` is the default store.
It is thread-safe and process-local, which makes it a strong fit for development, single-instance deployments, and lightweight production services.

You can also cap the number of retained entries:

```crystal
store = Kemal::Cache::MemoryStore.new(max_entries: 10_000)
config = Kemal::Cache::Config.new(store: store)
```

When the limit is reached, the oldest entry is evicted on the next write.

### `RedisStore`

`RedisStore` is intended for shared caching across multiple application instances:

```crystal
require "kemal-cache/redis"

store = Kemal::Cache::RedisStore.new(
  URI.parse("redis://localhost:6379/0"),
  namespace: "my-app-cache"
)

config = Kemal::Cache::Config.new(store: store)
use Kemal::Cache::Handler.new(config)
```

You can also build it from an environment variable:

```crystal
store = Kemal::Cache::RedisStore.from_env("REDIS_URL")
config = Kemal::Cache::Config.new(store: store)
```

`RedisStore#clear` removes namespaced keys using Redis `SCAN`, which avoids the blocking behavior of `KEYS` on large datasets.

### Custom Stores

Build your own store by inheriting from `Kemal::Cache::Store`:

```crystal
class CustomStore < Kemal::Cache::Store
  def get(key : String) : String?
    # fetch from storage
  end

  def set(key : String, value : String, ttl : Time::Span) : Nil
    # write to storage with ttl
  end

  def delete(key : String) : Nil
    # delete a single key
  end

  def clear : Nil
    # clear the namespace
  end
end
```

Wire it into the config:

```crystal
config = Kemal::Cache::Config.new(store: CustomStore.new)
use Kemal::Cache::Handler.new(config)
```

## Invalidation

Remove a cached entry by exact key:

```crystal
config = Kemal::Cache::Config.new
config.invalidate("/articles?page=2")
```

Invalidate directly from a request context when the key depends on request data:

```crystal
post "/articles/cache/invalidate" do |env|
  config.invalidate(env)
  env.response.status_code = 204
end
```

Purge the configured store:

```crystal
config.clear_cache
```

## Observability

Each config instance exposes thread-safe counters:

```crystal
config.stats.hits
config.stats.misses
config.stats.cacheable_requests
config.stats.stores
config.stats.bypasses
config.stats.not_modified
config.stats.invalidations
config.stats.clears
config.stats.requests
config.stats.hit_ratio
```

Semantics:

- `not_modified` is a subset of `hits`
- `cacheable_requests` is `hits + misses`
- `requests` is `cacheable_requests + bypasses`

You can also subscribe to lifecycle events:

```crystal
config = Kemal::Cache::Config.new(
  on_event: ->(event : Kemal::Cache::Event) do
    Log.info do
      "type=#{event.type} key=#{event.key} path=#{event.path} " \
      "method=#{event.http_method} status=#{event.status_code} detail=#{event.detail}"
    end
  end
)

use Kemal::Cache::Handler.new(config)
```

Available event types:

- `Hit`
- `Miss`
- `Store`
- `Bypass`
- `NotModified`
- `Invalidate`
- `Clear`

Common bypass details include `disabled`, `method_not_cacheable`, `skip_if`, `authorization_header`, and `cookie_header`.

## Operational Notes

- `MemoryStore` is process-local, so each app instance keeps its own cache.
- Use `RedisStore` when multiple instances should share cached responses.
- `clear_cache` only clears the configured store namespace.
- Corrupt cached payloads are discarded automatically and retried as cache misses.
- Upstream middleware headers are preserved unless the cached response intentionally replaces the same header name.

## How It Works

On a cache miss, the middleware buffers the response body, decides whether the response is storable, persists it with the configured TTL, and then writes the response to the client.

On a cache hit, it restores the cached body, status, and response headers without invoking the rest of the handler chain.

For safer defaults, the middleware bypasses authenticated and cookie-bearing requests and refuses to store responses that explicitly opt out of caching.

## Development

```bash
shards install
crystal spec
crystal tool format --check
```

To run the real Redis integration spec locally, start Redis and set `REDIS_URL`:

```bash
REDIS_URL=redis://localhost:6379/0 crystal spec
```

## Contributing

1. Fork it (<https://github.com/kemalcr/kemal-cache/fork>)
2. Create your feature branch (`git checkout -b my-new-feature`)
3. Commit your changes (`git commit -am 'Add some feature'`)
4. Push to the branch (`git push origin my-new-feature`)
5. Create a new Pull Request

## Contributors

- [Serdar Dogruyol](https://github.com/sdogruyol) - Author
