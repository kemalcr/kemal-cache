# Unreleased

- Made Redis support opt-in via `require "kemal-cache/redis"` so the core middleware can be used without a runtime Redis dependency.
- Switched `RedisStore#clear` from `KEYS` to cursor-based `SCAN` iteration.
- Invalidates corrupt cached payloads and falls back to a cache miss instead of failing the request.

# 1.0.0 - (04-02-2026)

Initial stable release of `kemal-cache`.

- Production-ready response caching middleware for Kemal.
- Safe-by-default cache behavior for authenticated, cookie-bearing, and non-cacheable responses.
- Successful `2xx` responses cached by default.
- `MemoryStore` as the default in-process backend.
- Built-in `RedisStore` backed by [`jgaskins/redis`](https://github.com/jgaskins/redis).
- Configurable cache keys with `key_generator`.
- Configurable cache methods and status-code policies.
- Request and response filters with `skip_if` and `should_cache`.
- Cache invalidation APIs with `invalidate(key)`, `invalidate(context)`, and `clear_cache`.
- Response size guards with `max_body_bytes`.
- Streaming guards with `cache_streaming`.
- Automatic `ETag` and `Last-Modified` generation for cached responses.
- Conditional GET support with `If-None-Match`, `If-Modified-Since`, and `304 Not Modified`.
- Built-in observability with `Stats`, `Event`, `EventType`, and `on_event`.
