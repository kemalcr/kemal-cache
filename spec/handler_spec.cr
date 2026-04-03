require "./spec_helper"

describe Kemal::Cache::Handler do
  it "caches successful responses by default" do
    state = RequestState.new

    mount_cache do
      get "/default-status" do |env|
        state.calls += 1
        env.response.status_code = 204
        ""
      end
    end

    get "/default-status"
    response.status_code.should eq 204
    response.headers["X-Kemal-Cache"].should eq "MISS"

    get "/default-status"
    response.status_code.should eq 204
    response.headers["X-Kemal-Cache"].should eq "HIT"
    state.calls.should eq 1
  end

  it "does not cache error responses by default" do
    state = RequestState.new

    mount_cache do
      get "/default-errors" do |env|
        state.calls += 1
        env.response.status_code = 500
        "error #{state.calls}"
      end
    end

    get "/default-errors"
    response.status_code.should eq 500
    response.headers["X-Kemal-Cache"].should eq "MISS"
    response.body.should eq "error 1"

    get "/default-errors"
    response.status_code.should eq 500
    response.headers["X-Kemal-Cache"].should eq "MISS"
    response.body.should eq "error 2"
    state.calls.should eq 2
  end

  it "uses a custom cache key generator when configured" do
    state = RequestState.new
    config = Kemal::Cache::Config.new(
      key_generator: ->(context : HTTP::Server::Context) { context.request.path }
    )

    mount_cache(config) do
      get "/custom-key" do
        state.calls += 1
        "page #{state.calls}"
      end
    end

    get "/custom-key?page=1"
    response.headers["X-Kemal-Cache"].should eq "MISS"
    response.body.should eq "page 1"

    get "/custom-key?page=2"
    response.headers["X-Kemal-Cache"].should eq "HIT"
    response.body.should eq "page 1"
    state.calls.should eq 1
  end

  it "returns MISS first and HIT on the next GET request" do
    state = RequestState.new

    mount_cache do
      get "/articles" do |env|
        state.calls += 1
        env.response.status_code = 202
        env.response.content_type = "text/plain; charset=utf-8"
        env.response.headers["X-App-Version"] = "v1"
        "expensive response"
      end
    end

    get "/articles"
    response.status_code.should eq 202
    response.content_type.should eq "text/plain"
    response.headers["X-App-Version"].should eq "v1"
    response.headers["X-Kemal-Cache"].should eq "MISS"
    response.body.should eq "expensive response"
    state.calls.should eq 1

    get "/articles"
    response.status_code.should eq 202
    response.content_type.should eq "text/plain"
    response.headers["X-App-Version"].should eq "v1"
    response.headers["X-Kemal-Cache"].should eq "HIT"
    response.body.should eq "expensive response"
    state.calls.should eq 1
  end

  it "bypasses cache when the request has an Authorization header" do
    state = RequestState.new

    mount_cache do
      get "/authorized" do
        state.calls += 1
        "authorized #{state.calls}"
      end
    end

    get "/authorized"
    response.headers["X-Kemal-Cache"].should eq "MISS"
    response.body.should eq "authorized 1"

    get "/authorized"
    response.headers["X-Kemal-Cache"].should eq "HIT"
    response.body.should eq "authorized 1"

    get "/authorized", headers: HTTP::Headers{"Authorization" => "Bearer token"}
    response.headers["X-Kemal-Cache"].should eq "MISS"
    response.body.should eq "authorized 2"

    get "/authorized"
    response.headers["X-Kemal-Cache"].should eq "HIT"
    response.body.should eq "authorized 1"
    state.calls.should eq 2
  end

  it "bypasses cache when the request has a Cookie header" do
    state = RequestState.new

    mount_cache do
      get "/cookies" do
        state.calls += 1
        "cookies #{state.calls}"
      end
    end

    get "/cookies"
    response.headers["X-Kemal-Cache"].should eq "MISS"
    response.body.should eq "cookies 1"

    get "/cookies"
    response.headers["X-Kemal-Cache"].should eq "HIT"
    response.body.should eq "cookies 1"

    get "/cookies", headers: HTTP::Headers{"Cookie" => "session=abc123"}
    response.headers["X-Kemal-Cache"].should eq "MISS"
    response.body.should eq "cookies 2"

    get "/cookies"
    response.headers["X-Kemal-Cache"].should eq "HIT"
    response.body.should eq "cookies 1"
    state.calls.should eq 2
  end

  it "supports custom skip_if rules" do
    state = RequestState.new
    config = Kemal::Cache::Config.new(
      skip_if: ->(context : HTTP::Server::Context) do
        context.request.query_params["preview"]? == "true"
      end
    )

    mount_cache(config) do
      get "/skip-if" do
        state.calls += 1
        "skip #{state.calls}"
      end
    end

    get "/skip-if"
    response.headers["X-Kemal-Cache"].should eq "MISS"
    response.body.should eq "skip 1"

    get "/skip-if"
    response.headers["X-Kemal-Cache"].should eq "HIT"
    response.body.should eq "skip 1"

    get "/skip-if?preview=true"
    response.headers["X-Kemal-Cache"].should eq "MISS"
    response.body.should eq "skip 2"

    get "/skip-if?preview=true"
    response.headers["X-Kemal-Cache"].should eq "MISS"
    response.body.should eq "skip 3"
    state.calls.should eq 3
  end

  it "supports custom should_cache rules" do
    state = RequestState.new
    config = Kemal::Cache::Config.new(
      should_cache: ->(context : HTTP::Server::Context) do
        context.response.status_code == 202
      end
    )

    mount_cache(config) do
      get "/should-cache" do |env|
        state.calls += 1
        env.response.status_code = state.calls == 1 ? 200 : 202
        "should #{state.calls}"
      end
    end

    get "/should-cache"
    response.status_code.should eq 200
    response.headers["X-Kemal-Cache"].should eq "MISS"
    response.body.should eq "should 1"

    get "/should-cache"
    response.status_code.should eq 202
    response.headers["X-Kemal-Cache"].should eq "MISS"
    response.body.should eq "should 2"

    get "/should-cache"
    response.status_code.should eq 202
    response.headers["X-Kemal-Cache"].should eq "HIT"
    response.body.should eq "should 2"
    state.calls.should eq 2
  end

  it "tracks cache stats" do
    config = Kemal::Cache::Config.new
    state = RequestState.new

    mount_cache(config) do
      get "/stats" do
        state.calls += 1
        "stats #{state.calls}"
      end
    end

    get "/stats"
    get "/stats"
    get "/stats", headers: HTTP::Headers{"Authorization" => "Bearer token"}
    config.invalidate("/stats")
    config.clear_cache

    config.stats.misses.should eq 1
    config.stats.stores.should eq 1
    config.stats.hits.should eq 1
    config.stats.bypasses.should eq 1
    config.stats.not_modified.should eq 0
    config.stats.invalidations.should eq 1
    config.stats.clears.should eq 1
    config.stats.cacheable_requests.should eq 2
    config.stats.requests.should eq 3
    config.stats.hit_ratio.should eq 0.5
  end

  it "counts 304 responses as hits in stats" do
    config = Kemal::Cache::Config.new
    state = RequestState.new

    mount_cache(config) do
      get "/stats-304" do
        state.calls += 1
        "stats-304 #{state.calls}"
      end
    end

    get "/stats-304"
    etag = response.headers["ETag"]

    get "/stats-304", headers: HTTP::Headers{"If-None-Match" => etag}
    response.status_code.should eq 304

    config.stats.hits.should eq 1
    config.stats.misses.should eq 1
    config.stats.not_modified.should eq 1
    config.stats.cacheable_requests.should eq 2
    config.stats.requests.should eq 2
    config.stats.hit_ratio.should eq 0.5
  end

  it "emits observable cache events" do
    events = [] of Kemal::Cache::Event
    config = Kemal::Cache::Config.new(
      on_event: ->(event : Kemal::Cache::Event) { events << event }
    )
    state = RequestState.new

    mount_cache(config) do
      get "/events" do
        state.calls += 1
        "events #{state.calls}"
      end
    end

    get "/events"
    etag = response.headers["ETag"]
    get "/events"
    get "/events", headers: HTTP::Headers{"If-None-Match" => etag}
    get "/events", headers: HTTP::Headers{"Authorization" => "Bearer token"}
    config.invalidate("/events")
    config.clear_cache

    events.map(&.type).should eq([
      Kemal::Cache::EventType::Store,
      Kemal::Cache::EventType::Miss,
      Kemal::Cache::EventType::Hit,
      Kemal::Cache::EventType::Hit,
      Kemal::Cache::EventType::NotModified,
      Kemal::Cache::EventType::Bypass,
      Kemal::Cache::EventType::Invalidate,
      Kemal::Cache::EventType::Clear,
    ])

    events[0].key.should eq "/events"
    events[0].path.should eq "/events"
    events[0].http_method.should eq "GET"
    events[4].status_code.should eq 304
    events[5].detail.should eq "authorization_header"
    events[6].key.should eq "/events"
  end

  it "invalidates cached entries by explicit key" do
    state = RequestState.new
    config = Kemal::Cache::Config.new

    mount_cache(config) do
      get "/invalidate-key" do
        state.calls += 1
        "key #{state.calls}"
      end
    end

    get "/invalidate-key"
    response.headers["X-Kemal-Cache"].should eq "MISS"
    response.body.should eq "key 1"

    get "/invalidate-key"
    response.headers["X-Kemal-Cache"].should eq "HIT"
    response.body.should eq "key 1"

    config.invalidate("/invalidate-key")

    get "/invalidate-key"
    response.headers["X-Kemal-Cache"].should eq "MISS"
    response.body.should eq "key 2"
    state.calls.should eq 2
  end

  it "invalidates cached entries from the current context" do
    state = RequestState.new
    config = Kemal::Cache::Config.new(
      key_generator: ->(context : HTTP::Server::Context) { context.request.path },
      skip_if: ->(context : HTTP::Server::Context) do
        context.request.query_params["invalidate"]? == "true"
      end
    )

    mount_cache(config) do
      get "/invalidate-context" do |env|
        if env.request.query_params["invalidate"]? == "true"
          config.invalidate(env)
          "invalidated"
        else
          state.calls += 1
          "context #{state.calls}"
        end
      end
    end

    get "/invalidate-context"
    response.headers["X-Kemal-Cache"].should eq "MISS"
    response.body.should eq "context 1"

    get "/invalidate-context"
    response.headers["X-Kemal-Cache"].should eq "HIT"
    response.body.should eq "context 1"

    get "/invalidate-context?invalidate=true"
    response.headers["X-Kemal-Cache"].should eq "MISS"
    response.body.should eq "invalidated"

    get "/invalidate-context"
    response.headers["X-Kemal-Cache"].should eq "MISS"
    response.body.should eq "context 2"
    state.calls.should eq 2
  end

  it "clears all cached entries through the config" do
    state = RequestState.new
    config = Kemal::Cache::Config.new

    mount_cache(config) do
      get "/clear-cache" do
        state.calls += 1
        "clear #{state.calls}"
      end
    end

    get "/clear-cache"
    response.headers["X-Kemal-Cache"].should eq "MISS"
    response.body.should eq "clear 1"

    get "/clear-cache"
    response.headers["X-Kemal-Cache"].should eq "HIT"
    response.body.should eq "clear 1"

    config.clear_cache

    get "/clear-cache"
    response.headers["X-Kemal-Cache"].should eq "MISS"
    response.body.should eq "clear 2"
    state.calls.should eq 2
  end

  it "does not persist responses larger than the configured body limit" do
    store = RecordingStore.new
    state = RequestState.new
    config = Kemal::Cache::Config.new(
      store: store,
      max_body_bytes: 5
    )

    mount_cache(config) do
      get "/large-body" do
        state.calls += 1
        "body-#{state.calls}"
      end
    end

    get "/large-body"
    response.headers["X-Kemal-Cache"].should eq "MISS"
    response.body.should eq "body-1"

    get "/large-body"
    response.headers["X-Kemal-Cache"].should eq "MISS"
    response.body.should eq "body-2"
    state.calls.should eq 2
    store.last_key.should be_nil
  end

  it "does not persist streaming responses by default" do
    store = RecordingStore.new
    state = RequestState.new
    config = Kemal::Cache::Config.new(store: store)

    mount_cache(config) do
      get "/streaming" do |env|
        state.calls += 1
        env.response.print "chunk-#{state.calls}"
        env.response.flush
        "-tail"
      end
    end

    get "/streaming"
    response.headers["X-Kemal-Cache"].should eq "MISS"
    response.body.should eq "chunk-1-tail"

    get "/streaming"
    response.headers["X-Kemal-Cache"].should eq "MISS"
    response.body.should eq "chunk-2-tail"
    state.calls.should eq 2
    store.last_key.should be_nil
  end

  it "can cache streaming responses when explicitly enabled" do
    state = RequestState.new
    config = Kemal::Cache::Config.new(cache_streaming: true)

    mount_cache(config) do
      get "/streaming-enabled" do |env|
        state.calls += 1
        env.response.print "stream-#{state.calls}"
        env.response.flush
        "-done"
      end
    end

    get "/streaming-enabled"
    response.headers["X-Kemal-Cache"].should eq "MISS"
    response.body.should eq "stream-1-done"

    get "/streaming-enabled"
    response.headers["X-Kemal-Cache"].should eq "HIT"
    response.body.should eq "stream-1-done"
    state.calls.should eq 1
  end

  it "can cache large responses when body limits are disabled" do
    state = RequestState.new
    config = Kemal::Cache::Config.new(max_body_bytes: nil)

    mount_cache(config) do
      get "/large-body-unlimited" do
        state.calls += 1
        "large-body-#{state.calls}"
      end
    end

    get "/large-body-unlimited"
    response.headers["X-Kemal-Cache"].should eq "MISS"
    response.body.should eq "large-body-1"

    get "/large-body-unlimited"
    response.headers["X-Kemal-Cache"].should eq "HIT"
    response.body.should eq "large-body-1"
    state.calls.should eq 1
  end

  it "adds ETag and Last-Modified headers to cached responses" do
    state = RequestState.new

    mount_cache do
      get "/validators" do
        state.calls += 1
        "validators #{state.calls}"
      end
    end

    get "/validators"
    response.headers["X-Kemal-Cache"].should eq "MISS"
    response.headers["ETag"]?.should_not be_nil
    response.headers["Last-Modified"]?.should_not be_nil

    etag = response.headers["ETag"]
    last_modified = response.headers["Last-Modified"]

    get "/validators"
    response.headers["X-Kemal-Cache"].should eq "HIT"
    response.headers["ETag"].should eq etag
    response.headers["Last-Modified"].should eq last_modified
    response.body.should eq "validators 1"
    state.calls.should eq 1
  end

  it "preserves existing ETag and Last-Modified headers" do
    state = RequestState.new

    mount_cache do
      get "/validators-preserved" do |env|
        state.calls += 1
        env.response.headers["ETag"] = %("custom-etag")
        env.response.headers["Last-Modified"] = "Mon, 01 Jan 2024 00:00:00 GMT"
        "preserved #{state.calls}"
      end
    end

    get "/validators-preserved"
    response.headers["X-Kemal-Cache"].should eq "MISS"
    response.headers["ETag"].should eq %("custom-etag")
    response.headers["Last-Modified"].should eq "Mon, 01 Jan 2024 00:00:00 GMT"

    get "/validators-preserved"
    response.headers["X-Kemal-Cache"].should eq "HIT"
    response.headers["ETag"].should eq %("custom-etag")
    response.headers["Last-Modified"].should eq "Mon, 01 Jan 2024 00:00:00 GMT"
    state.calls.should eq 1
  end

  it "does not auto-generate validators when disabled" do
    state = RequestState.new
    config = Kemal::Cache::Config.new(
      auto_etag: false,
      auto_last_modified: false
    )

    mount_cache(config) do
      get "/validators-disabled" do
        state.calls += 1
        "disabled #{state.calls}"
      end
    end

    get "/validators-disabled"
    response.headers["X-Kemal-Cache"].should eq "MISS"
    response.headers["ETag"]?.should be_nil
    response.headers["Last-Modified"]?.should be_nil

    get "/validators-disabled"
    response.headers["X-Kemal-Cache"].should eq "HIT"
    response.headers["ETag"]?.should be_nil
    response.headers["Last-Modified"]?.should be_nil
    state.calls.should eq 1
  end

  it "returns 304 for matching If-None-Match requests" do
    state = RequestState.new

    mount_cache do
      get "/etag-304" do
        state.calls += 1
        "etag #{state.calls}"
      end
    end

    get "/etag-304"
    etag = response.headers["ETag"]

    get "/etag-304", headers: HTTP::Headers{"If-None-Match" => etag}
    response.status_code.should eq 304
    response.headers["X-Kemal-Cache"].should eq "HIT"
    response.body.should eq ""
    response.headers["ETag"].should eq etag
    state.calls.should eq 1
  end

  it "returns 304 for matching If-Modified-Since requests" do
    state = RequestState.new

    mount_cache do
      get "/last-modified-304" do
        state.calls += 1
        "last-modified #{state.calls}"
      end
    end

    get "/last-modified-304"
    last_modified = response.headers["Last-Modified"]

    get "/last-modified-304", headers: HTTP::Headers{"If-Modified-Since" => last_modified}
    response.status_code.should eq 304
    response.headers["X-Kemal-Cache"].should eq "HIT"
    response.body.should eq ""
    response.headers["Last-Modified"].should eq last_modified
    state.calls.should eq 1
  end

  it "does not return 304 when conditional GET support is disabled" do
    state = RequestState.new
    config = Kemal::Cache::Config.new(conditional_get: false)

    mount_cache(config) do
      get "/conditional-disabled" do
        state.calls += 1
        "conditional #{state.calls}"
      end
    end

    get "/conditional-disabled"
    etag = response.headers["ETag"]

    get "/conditional-disabled", headers: HTTP::Headers{"If-None-Match" => etag}
    response.status_code.should eq 200
    response.headers["X-Kemal-Cache"].should eq "HIT"
    response.body.should eq "conditional 1"
    state.calls.should eq 1
  end

  it "prefers If-None-Match over If-Modified-Since" do
    state = RequestState.new

    mount_cache do
      get "/validator-precedence" do
        state.calls += 1
        "precedence #{state.calls}"
      end
    end

    get "/validator-precedence"
    last_modified = response.headers["Last-Modified"]

    get "/validator-precedence", headers: HTTP::Headers{
      "If-None-Match"     => %("does-not-match"),
      "If-Modified-Since" => last_modified,
    }
    response.status_code.should eq 200
    response.headers["X-Kemal-Cache"].should eq "HIT"
    response.body.should eq "precedence 1"
    state.calls.should eq 1
  end

  it "uses the full request resource including query params as the cache key" do
    state = RequestState.new

    mount_cache do
      get "/items" do
        state.calls += 1
        "page #{state.calls}"
      end
    end

    get "/items?page=1"
    response.headers["X-Kemal-Cache"].should eq "MISS"
    response.body.should eq "page 1"

    get "/items?page=2"
    response.headers["X-Kemal-Cache"].should eq "MISS"
    response.body.should eq "page 2"

    get "/items?page=1"
    response.headers["X-Kemal-Cache"].should eq "HIT"
    response.body.should eq "page 1"
    state.calls.should eq 2
  end

  it "does not cache non-GET requests" do
    state = RequestState.new

    mount_cache do
      post "/posts" do
        state.calls += 1
        "post #{state.calls}"
      end
    end

    post "/posts"
    response.headers["X-Kemal-Cache"].should eq "MISS"
    response.body.should eq "post 1"

    post "/posts"
    response.headers["X-Kemal-Cache"].should eq "MISS"
    response.body.should eq "post 2"
    state.calls.should eq 2
  end

  it "caches configured HTTP methods" do
    state = RequestState.new
    config = Kemal::Cache::Config.new(cacheable_methods: ["GET", "POST"])

    mount_cache(config) do
      post "/cached-posts" do
        state.calls += 1
        "post #{state.calls}"
      end
    end

    post "/cached-posts"
    response.headers["X-Kemal-Cache"].should eq "MISS"
    response.body.should eq "post 1"

    post "/cached-posts"
    response.headers["X-Kemal-Cache"].should eq "HIT"
    response.body.should eq "post 1"
    state.calls.should eq 1
  end

  it "respects the enabled flag" do
    events = [] of Kemal::Cache::Event
    config = Kemal::Cache::Config.new(
      enabled: false,
      on_event: ->(event : Kemal::Cache::Event) { events << event }
    )
    state = RequestState.new

    mount_cache(config) do
      get "/disabled" do
        state.calls += 1
        "disabled #{state.calls}"
      end
    end

    get "/disabled"
    response.headers["X-Kemal-Cache"].should eq "MISS"
    response.body.should eq "disabled 1"

    get "/disabled"
    response.headers["X-Kemal-Cache"].should eq "MISS"
    response.body.should eq "disabled 2"
    state.calls.should eq 2
    config.store.get("/disabled").should be_nil
    events.map(&.detail).uniq.should eq(["disabled"])
  end

  it "preserves headers set before the cache handler on hits" do
    config = Kemal::Cache::Config.new
    state = RequestState.new
    request_counter = 0

    use RequestHeaderHandler.new("X-Request-Id", ->(_context : HTTP::Server::Context) do
      request_counter += 1
      "req-#{request_counter}"
    end)
    use Kemal::Cache::Handler.new(config)
    get "/upstream-headers" do |env|
      state.calls += 1
      env.response.headers["X-Route-Version"] = "route-#{state.calls}"
      "upstream #{state.calls}"
    end
    Kemal.config.setup

    get "/upstream-headers"
    response.headers["X-Kemal-Cache"].should eq "MISS"
    response.headers["X-Request-Id"].should eq "req-1"
    response.headers["X-Route-Version"].should eq "route-1"

    get "/upstream-headers"
    response.headers["X-Kemal-Cache"].should eq "HIT"
    response.headers["X-Request-Id"].should eq "req-2"
    response.headers["X-Route-Version"].should eq "route-1"
    state.calls.should eq 1
  end

  it "expires cached responses using the configured ttl" do
    config = Kemal::Cache::Config.new(expires_in: 5.milliseconds)
    state = RequestState.new

    mount_cache(config) do
      get "/ttl" do
        state.calls += 1
        "ttl #{state.calls}"
      end
    end

    get "/ttl"
    response.headers["X-Kemal-Cache"].should eq "MISS"
    response.body.should eq "ttl 1"

    sleep 10.milliseconds

    get "/ttl"
    response.headers["X-Kemal-Cache"].should eq "MISS"
    response.body.should eq "ttl 2"
    state.calls.should eq 2
  end

  it "caches only responses with allowed status codes" do
    state = RequestState.new
    config = Kemal::Cache::Config.new(cacheable_status_codes: [202])

    mount_cache(config) do
      get "/status" do |env|
        state.calls += 1
        env.response.status_code = state.calls == 1 ? 500 : 202
        "status #{state.calls}"
      end
    end

    get "/status"
    response.status_code.should eq 500
    response.headers["X-Kemal-Cache"].should eq "MISS"
    response.body.should eq "status 1"

    get "/status"
    response.status_code.should eq 202
    response.headers["X-Kemal-Cache"].should eq "MISS"
    response.body.should eq "status 2"

    get "/status"
    response.status_code.should eq 202
    response.headers["X-Kemal-Cache"].should eq "HIT"
    response.body.should eq "status 2"
    state.calls.should eq 2
  end

  it "passes the request resource and configured ttl to the store" do
    store = RecordingStore.new
    config = Kemal::Cache::Config.new(expires_in: 15.seconds, store: store)

    mount_cache(config) do
      get "/tracked" do
        "tracked response"
      end
    end

    get "/tracked?page=2"
    response.headers["X-Kemal-Cache"].should eq "MISS"

    store.last_key.should eq "/tracked?page=2"
    store.last_ttl.should eq 15.seconds
    store.last_value.should_not be_nil
  end

  it "invalidates corrupt cached payloads and falls back to a miss" do
    store = RecordingStore.new
    store.prime("/corrupt", %({"status_code":"oops"}))
    config = Kemal::Cache::Config.new(store: store)
    state = RequestState.new

    mount_cache(config) do
      get "/corrupt" do
        state.calls += 1
        "corrupt #{state.calls}"
      end
    end

    get "/corrupt"
    response.headers["X-Kemal-Cache"].should eq "MISS"
    response.body.should eq "corrupt 1"
    config.stats.invalidations.should eq 1

    get "/corrupt"
    response.headers["X-Kemal-Cache"].should eq "HIT"
    response.body.should eq "corrupt 1"
    state.calls.should eq 1
  end

  it "does not persist disallowed status codes" do
    store = RecordingStore.new
    config = Kemal::Cache::Config.new(
      store: store,
      cacheable_status_codes: [200]
    )

    mount_cache(config) do
      get "/errors" do |env|
        env.response.status_code = 500
        "error"
      end
    end

    get "/errors"
    response.headers["X-Kemal-Cache"].should eq "MISS"
    store.last_key.should be_nil
    store.last_value.should be_nil
  end

  it "does not persist responses that set cookies" do
    store = RecordingStore.new
    state = RequestState.new
    config = Kemal::Cache::Config.new(store: store)

    mount_cache(config) do
      get "/set-cookie" do |env|
        state.calls += 1
        env.response.headers.add("Set-Cookie", "session=#{state.calls}; Path=/; HttpOnly")
        "cookie #{state.calls}"
      end
    end

    get "/set-cookie"
    response.headers["X-Kemal-Cache"].should eq "MISS"
    response.body.should eq "cookie 1"

    get "/set-cookie"
    response.headers["X-Kemal-Cache"].should eq "MISS"
    response.body.should eq "cookie 2"
    state.calls.should eq 2
    store.last_key.should be_nil
  end

  it "does not persist responses with cache-control directives that disallow storage" do
    store = RecordingStore.new
    state = RequestState.new
    config = Kemal::Cache::Config.new(store: store)

    mount_cache(config) do
      get "/no-store" do |env|
        state.calls += 1
        env.response.headers["Cache-Control"] = "no-store, max-age=60"
        "no-store #{state.calls}"
      end

      get "/no-cache" do |env|
        state.calls += 1
        env.response.headers["Cache-Control"] = "no-cache"
        "no-cache #{state.calls}"
      end

      get "/private-cache" do |env|
        state.calls += 1
        env.response.headers["Cache-Control"] = "private"
        "private #{state.calls}"
      end
    end

    get "/no-store"
    response.headers["X-Kemal-Cache"].should eq "MISS"
    response.body.should eq "no-store 1"

    get "/no-store"
    response.headers["X-Kemal-Cache"].should eq "MISS"
    response.body.should eq "no-store 2"

    get "/no-cache"
    response.headers["X-Kemal-Cache"].should eq "MISS"
    response.body.should eq "no-cache 3"

    get "/no-cache"
    response.headers["X-Kemal-Cache"].should eq "MISS"
    response.body.should eq "no-cache 4"

    get "/private-cache"
    response.headers["X-Kemal-Cache"].should eq "MISS"
    response.body.should eq "private 5"

    get "/private-cache"
    response.headers["X-Kemal-Cache"].should eq "MISS"
    response.body.should eq "private 6"

    state.calls.should eq 6
    store.last_key.should be_nil
  end

  it "does not persist responses with Vary: *" do
    store = RecordingStore.new
    state = RequestState.new
    config = Kemal::Cache::Config.new(store: store)

    mount_cache(config) do
      get "/vary-star" do |env|
        state.calls += 1
        env.response.headers["Vary"] = "*"
        "vary #{state.calls}"
      end
    end

    get "/vary-star"
    response.headers["X-Kemal-Cache"].should eq "MISS"
    response.body.should eq "vary 1"

    get "/vary-star"
    response.headers["X-Kemal-Cache"].should eq "MISS"
    response.body.should eq "vary 2"
    state.calls.should eq 2
    store.last_key.should be_nil
  end
end
