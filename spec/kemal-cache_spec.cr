require "./spec_helper"

private class RequestState
  property calls : Int32

  def initialize
    @calls = 0
  end
end

private class RecordingStore < Kemal::Cache::Store
  getter last_key : String?
  getter last_value : String?
  getter last_ttl : Time::Span?

  def initialize
    @entries = {} of String => String
  end

  def get(key : String) : String?
    @entries[key]?
  end

  def set(key : String, value : String, ttl : Time::Span) : Nil
    @last_key = key
    @last_value = value
    @last_ttl = ttl
    @entries[key] = value
  end

  def delete(key : String) : Nil
    @entries.delete(key)
  end

  def clear : Nil
    @entries.clear
  end
end

private def mount_cache(config : Kemal::Cache::Config = Kemal::Cache::Config.new, &)
  use Kemal::Cache::Handler.new(config)
  yield
  Kemal.config.setup
end

describe Kemal::Cache do
  describe Kemal::Cache::MemoryStore do
    it "stores, deletes, clears, and expires values" do
      store = Kemal::Cache::MemoryStore.new

      store.set("greeting", "hello", 20.milliseconds)
      store.get("greeting").should eq("hello")

      store.delete("greeting")
      store.get("greeting").should be_nil

      store.set("one", "1", 20.milliseconds)
      store.set("two", "2", 20.milliseconds)
      store.clear
      store.get("one").should be_nil
      store.get("two").should be_nil

      store.set("short", "ttl", 5.milliseconds)
      sleep 10.milliseconds
      store.get("short").should be_nil
    end
  end

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
      config = Kemal::Cache::Config.new(enabled: false)
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
end
