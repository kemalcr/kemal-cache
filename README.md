# kemal-cache

[![CI](https://github.com/kemalcr/kemal-cache/actions/workflows/ci.yml/badge.svg)](https://github.com/kemalcr/kemal-cache/actions/workflows/ci.yml)

`kemal-cache` is a response caching middleware for [Kemal](https://kemalcr.com/).
It is intentionally small, storage-agnostic, and safe by default.

## Highlights

- Kemal-native middleware API
- safe defaults for authenticated, cookie-bearing, and non-cacheable responses
- in-memory and Redis-backed stores
- custom cache keys, filters, and invalidation
- HTTP validator support with `ETag`, `Last-Modified`, and `304 Not Modified`
- built-in observability via counters and event hooks

## Installation

Add the shard to `shard.yml`:

```yaml
dependencies:
  kemal-cache:
    github: kemalcr/kemal-cache
```

Then install dependencies:

```bash
shards install
```

`require "kemal-cache"` only loads the core middleware and `MemoryStore`.
If you want `RedisStore`, add `redis` to your application's `shard.yml` and require `kemal-cache/redis`.

## Quick Start

```crystal
require "kemal-cache"

use Kemal::Cache::Handler.new

get "/articles" do
  "Expensive response"
end

Kemal.run
```

The middleware adds `X-Kemal-Cache: MISS` or `X-Kemal-Cache: HIT` so cache behavior is visible during development.

## Default Behavior

Out of the box, `kemal-cache`:

- caches `GET` requests only
- uses `context.request.resource` as the cache key
- caches successful `2xx` responses only
- stores entries for `10.minutes`
- uses the in-process `Kemal::Cache::MemoryStore`
- bypasses cache for requests with `Authorization` or `Cookie`
- skips storing responses with `Set-Cookie`
- skips storing responses with `Cache-Control: no-store`, `no-cache`, or `private`
- skips storing responses with `Vary: *`
- skips storing responses larger than `1_048_576` bytes
- skips storing responses that call `flush`
- auto-generates `ETag` and `Last-Modified` for cached responses
- answers matching conditional requests with `304 Not Modified`

## Configuration

Create a custom `Kemal::Cache::Config` when you want to override the defaults:

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

The default key is `context.request.resource`, which includes the path and query string.
Override it with `key_generator` when you need coarser or finer cache granularity:

```crystal
config = Kemal::Cache::Config.new(
  key_generator: ->(context : HTTP::Server::Context) do
    locale = context.request.headers["Accept-Language"]? || "default"
    "#{context.request.path}:#{locale}"
  end
)
```

### Cacheable Methods and Status Codes

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

### Request and Response Filters

Use `skip_if` to bypass both lookup and storage for matching requests:

```crystal
config = Kemal::Cache::Config.new(
  skip_if: ->(context : HTTP::Server::Context) do
    context.request.query_params["preview"]? == "true"
  end
)
```

Use `should_cache` for the final storage decision after the response has been built:

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

### Response Size and Streaming Guards

Adjust the body size limit:

```crystal
config = Kemal::Cache::Config.new(
  max_body_bytes: 128_000
)
```

Disable the size limit entirely:

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

Validator support is enabled by default for cached responses:

```crystal
config = Kemal::Cache::Config.new(
  auto_etag: true,
  auto_last_modified: true,
  conditional_get: true
)
```

If your application already manages these headers, `kemal-cache` preserves them.
You can also disable automatic validators or conditional handling:

```crystal
config = Kemal::Cache::Config.new(
  auto_etag: false,
  auto_last_modified: false,
  conditional_get: false
)
```

## Stores

### MemoryStore

`Kemal::Cache::MemoryStore` is the default store. It is protected by a `Mutex` and is safe to use in Crystal's multi-threaded runtime. Because it is process-local, it is best suited to development and single-instance deployments.

You can also cap the number of retained entries. When the limit is reached, the oldest entry is evicted on the next write:

```crystal
store = Kemal::Cache::MemoryStore.new(max_entries: 10_000)
config = Kemal::Cache::Config.new(store: store)
```

### RedisStore

`kemal-cache` includes a built-in `RedisStore` backed by [`jgaskins/redis`](https://github.com/jgaskins/redis):

```yaml
dependencies:
  kemal-cache:
    github: kemalcr/kemal-cache
  redis:
    github: jgaskins/redis
```

```crystal
require "kemal-cache/redis"

store = Kemal::Cache::RedisStore.new(
  URI.parse("redis://localhost:6379/0"),
  namespace: "my-app-cache"
)

config = Kemal::Cache::Config.new(store: store)
use Kemal::Cache::Handler.new(config)
```

You can also build a Redis store from an environment variable:

```crystal
store = Kemal::Cache::RedisStore.from_env("REDIS_URL")
config = Kemal::Cache::Config.new(store: store)
```

`RedisStore#clear` removes namespaced keys with Redis `SCAN`, so it avoids the blocking behavior of `KEYS` on large datasets.

### Custom Stores

Create a custom store by inheriting from `Kemal::Cache::Store`:

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

Then wire it into the config:

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

If the key depends on the current request context, invalidate directly from a route:

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

Each config instance exposes thread-safe counters through `config.stats`:

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

`not_modified` is a subset of `hits`, because conditional `304 Not Modified` responses are still cache hits.
`cacheable_requests` counts `hits + misses`, while `requests` adds bypassed requests on top.

You can also subscribe to cache lifecycle events with `on_event`:

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

## How It Works

On a cache miss, the middleware buffers the response body, stores it with the configured TTL, and then writes the response back to the client. On a cache hit, it restores the cached response without invoking the rest of the handler chain.

For safer defaults, the middleware bypasses authenticated and cookie-bearing requests and does not persist responses that explicitly opt out of storage.

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
