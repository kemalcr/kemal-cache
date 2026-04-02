# kemal-cache

`kemal-cache` is a lightweight response caching middleware for [Kemal](https://kemalcr.com/).
It is designed to feel native to the `Kemal` ecosystem: small API surface, storage-agnostic,
and safe to use in Crystal's multi-threaded runtime.

## Installation

1. Add the dependency to your `shard.yml`:

   ```yaml
   dependencies:
     kemal-cache:
       github: kemalcr/kemal-cache
   ```

2. Run `shards install`

## Usage

```crystal
require "kemal-cache"

use Kemal::Cache::Handler.new

get "/articles" do
  "Expensive response"
end

Kemal.run
```

By default the middleware:

- caches `GET` requests only
- bypasses cache for requests with `Authorization` or `Cookie` headers
- uses `context.request.resource` as the cache key
- caches successful `2xx` response status codes
- skips storing responses with `Set-Cookie`, `Cache-Control: no-store/no-cache/private`, or `Vary: *`
- skips storing responses larger than `1_048_576` bytes
- skips storing responses that call `flush`
- stores responses for `10.minutes`
- uses the in-process `Kemal::Cache::MemoryStore`
- adds `X-Kemal-Cache: MISS` or `X-Kemal-Cache: HIT`

### Custom configuration

```crystal
require "kemal-cache"

store = Kemal::Cache::MemoryStore.new
config = Kemal::Cache::Config.new(
  expires_in: 2.minutes,
  store: store,
  enabled: true,
  cacheable_methods: ["GET"],
  cacheable_status_codes: [200, 202],
  max_body_bytes: 128_000,
  cache_streaming: false,
  skip_if: ->(context : HTTP::Server::Context) { context.request.path.starts_with?("/admin") },
  should_cache: ->(context : HTTP::Server::Context) { context.response.status_code == 202 }
)

use Kemal::Cache::Handler.new(config)
```

### Custom cache key generation

Use `key_generator` when the default `request.resource` key is too granular or not granular enough:

```crystal
config = Kemal::Cache::Config.new(
  key_generator: ->(context : HTTP::Server::Context) do
    locale = context.request.headers["Accept-Language"]? || "default"
    "#{context.request.path}:#{locale}"
  end
)

use Kemal::Cache::Handler.new(config)
```

### Custom cacheable methods

By default, only `GET` responses are cached. You can opt in to other methods:

```crystal
config = Kemal::Cache::Config.new(
  cacheable_methods: ["GET", "POST"]
)

use Kemal::Cache::Handler.new(config)
```

### Custom status-code policy

By default, `kemal-cache` stores successful `2xx` responses only.
Override it when you want to persist a narrower or broader set of responses:

```crystal
config = Kemal::Cache::Config.new(
  cacheable_status_codes: [200, 203, 301]
)

use Kemal::Cache::Handler.new(config)
```

Pass `nil` to cache every response status code:

```crystal
config = Kemal::Cache::Config.new(
  cacheable_status_codes: nil
)

use Kemal::Cache::Handler.new(config)
```

### Response size and streaming guards

By default, `kemal-cache` only persists responses up to `1_048_576` bytes and skips
responses that call `flush`.

Adjust or disable the size limit with `max_body_bytes`:

```crystal
config = Kemal::Cache::Config.new(
  max_body_bytes: 128_000
)

use Kemal::Cache::Handler.new(config)
```

Pass `nil` to remove the size limit:

```crystal
config = Kemal::Cache::Config.new(
  max_body_bytes: nil
)

use Kemal::Cache::Handler.new(config)
```

Opt in to caching responses that flush their output:

```crystal
config = Kemal::Cache::Config.new(
  cache_streaming: true
)

use Kemal::Cache::Handler.new(config)
```

### Custom cache filters

Use `skip_if` to bypass cache lookup and storage for matching requests:

```crystal
config = Kemal::Cache::Config.new(
  skip_if: ->(context : HTTP::Server::Context) do
    context.request.query_params["preview"]? == "true"
  end
)

use Kemal::Cache::Handler.new(config)
```

Use `should_cache` to make the final storage decision after the response has been built.
It complements the built-in safety checks and can inspect `context.response`:

```crystal
config = Kemal::Cache::Config.new(
  should_cache: ->(context : HTTP::Server::Context) do
    context.response.status_code == 202
  end
)

use Kemal::Cache::Handler.new(config)
```

### Cache invalidation

Use `invalidate` to remove a specific cached entry by its exact key:

```crystal
config = Kemal::Cache::Config.new

config.invalidate("/articles?page=2")
```

If you are invalidating from inside a Kemal route and your cache key depends on the
current `HTTP::Server::Context`, pass the context directly:

```crystal
post "/articles/cache/invalidate" do |env|
  config.invalidate(env)
  env.response.status_code = 204
end
```

Use `clear_cache` to purge the configured store:

```crystal
config.clear_cache
```

### Custom store

`kemal-cache` includes a built-in `RedisStore` backed by
[`jgaskins/redis`](https://github.com/jgaskins/redis):

```crystal
store = Kemal::Cache::RedisStore.new(
  URI.parse("redis://localhost:6379/0"),
  namespace: "my-app-cache"
)

config = Kemal::Cache::Config.new(store: store)
use Kemal::Cache::Handler.new(config)
```

You can also build a custom store by inheriting from `Kemal::Cache::Store`:

```crystal
class RedisStore < Kemal::Cache::Store
  def get(key : String) : String?
    # fetch from Redis
  end

  def set(key : String, value : String, ttl : Time::Span) : Nil
    # write to Redis with ttl
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
config = Kemal::Cache::Config.new(store: RedisStore.new)
use Kemal::Cache::Handler.new(config)
```

## How It Works

On a cache miss, the middleware buffers the response body, stores it with the configured TTL,
and then writes the response back to the client. On a cache hit, it restores the cached response
without invoking the rest of the handler chain.

The default `MemoryStore` is protected by a `Mutex`, making it safe for Kemal applications
running in MT mode. Because it is process-local, it is best suited to single-instance deployments
or development environments.

For safer defaults, the middleware bypasses caching for authenticated or cookie-bearing requests,
and it will not persist responses that explicitly opt out of storage or set cookies.

## Development

```bash
shards install
crystal spec
```

## Contributing

1. Fork it (<https://github.com/kemalcr/kemal-cache/fork>)
2. Create your feature branch (`git checkout -b my-new-feature`)
3. Commit your changes (`git commit -am 'Add some feature'`)
4. Push to the branch (`git push origin my-new-feature`)
5. Create a new Pull Request

## Contributors

- [Serdar Dogruyol](https://github.com/sdogruyol) - creator and maintainer
