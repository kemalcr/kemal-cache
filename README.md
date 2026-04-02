# kemal-cache

`kemal-cache` is a lightweight response caching middleware for [Kemal](https://kemalcr.com/).
It is designed to feel native to the `kemalcr` ecosystem: small API surface, storage-agnostic,
and safe to use in Crystal's multi-threaded runtime.

## Installation

1. Add the dependency to your `shard.yml`:

   ```yaml
   dependencies:
     kemal:
       github: kemalcr/kemal
     kemal-cache:
       github: kemalcr/kemal-cache
   ```

2. Run `shards install`

## Usage

```crystal
require "kemal-cache"

add_handler Kemal::Cache::Handler.new

get "/articles" do
  "Expensive response"
end

Kemal.run
```

By default the middleware:

- caches `GET` requests only
- uses `context.request.resource` as the cache key
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
  enabled: true
)

add_handler Kemal::Cache::Handler.new(config)
```

### Custom store

Create a store by inheriting from `Kemal::Cache::Store`:

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
add_handler Kemal::Cache::Handler.new(config)
```

## How It Works

On a cache miss, the middleware buffers the response body, stores it with the configured TTL,
and then writes the response back to the client. On a cache hit, it restores the cached response
without invoking the rest of the handler chain.

The default `MemoryStore` is protected by a `Mutex`, making it safe for Kemal applications
running in MT mode. Because it is process-local, it is best suited to single-instance deployments
or development environments.

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
