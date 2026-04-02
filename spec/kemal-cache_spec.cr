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
  end
end
