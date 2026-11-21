require "./redis_helper"

describe Kemal::Cache::RedisStore do
  it "works against a real Redis instance" do
    redis_url = real_redis_url
    pending!("REDIS_URL is not set") unless redis_url

    namespace = unique_redis_namespace("kemal-cache-integration")
    other_namespace = unique_redis_namespace("kemal-cache-integration-other")
    store = Kemal::Cache::RedisStore.new(redis_url, namespace)
    client = Redis::Client.new(URI.parse(redis_url))

    begin
      store.clear
      client.del("#{other_namespace}:keep")

      store.set("greeting", "hello", 1.minute)
      store.get("greeting").should eq("hello")

      store.delete("greeting")
      store.get("greeting").should be_nil

      store.set("one", "1", 1.minute)
      store.set("two", "2", 1.minute)
      client.set("#{other_namespace}:keep", "3", ex: 1.minute)
      store.clear

      store.get("one").should be_nil
      store.get("two").should be_nil
      client.get("#{other_namespace}:keep").should eq("3")

      store.set("short", "ttl", 5.milliseconds)
      sleep 10.milliseconds
      store.get("short").should be_nil
    ensure
      store.clear
      client.del("#{other_namespace}:keep")
    end
  end
end

describe "Redis cache regressions" do
  it "clears only the selected namespace" do
    redis_url = real_redis_url
    pending!("REDIS_URL is not set") unless redis_url
    id = unique_redis_namespace
    store = Kemal::Cache::RedisStore.new(redis_url, "#{id}[x]")
    glob_neighbor = Kemal::Cache::RedisStore.new(redis_url, "#{id}x")
    nested_neighbor = Kemal::Cache::RedisStore.new(redis_url, "#{id}[x]:nested")
    begin
      store.set("own", "data", 1.minute)
      redis = Redis::Client.new(URI.parse(redis_url))
      keys = [] of String
      redis.scan_each(match: "kemal-cache:*") { |key| keys << key }
      keys.any? { |key| key.ends_with?(":entry:own") }.should be_false
      glob_neighbor.set("keep", "glob", 1.minute)
      nested_neighbor.set("keep", "nested", 1.minute)
      store.clear
      store.get("own").should be_nil
      glob_neighbor.get("keep").should eq("glob")
      nested_neighbor.get("keep").should eq("nested")
    ensure
      store.clear
      glob_neighbor.clear
      nested_neighbor.clear
    end
  end

  it "clears large namespaces with a one-connection pool" do
    redis_url = real_redis_url
    pending!("REDIS_URL is not set") unless redis_url
    url = URI.parse(redis_url)
    params = url.query_params
    params["max_pool_size"] = "1"
    params["checkout_timeout"] = "0.05"
    url.query = params.to_s
    store = Kemal::Cache::RedisStore.new(url, unique_redis_namespace)
    begin
      1000.times { |i| store.set(i.to_s, "data", 1.minute) }
      store.clear
      1000.times { |i| store.get(i.to_s).should be_nil }
    ensure
      store.clear
    end
  end

  it "accepts a positive submillisecond TTL" do
    redis_url = real_redis_url
    pending!("REDIS_URL is not set") unless redis_url
    store = Kemal::Cache::RedisStore.new(redis_url, unique_redis_namespace)
    begin
      store.set("short", "data", 500.microseconds)
      sleep 10.milliseconds
      store.get("short").should be_nil
    ensure
      store.clear
    end
  end

  it "fences in-flight writes across separate Redis store instances" do
    redis_url = real_redis_url
    pending!("REDIS_URL is not set") unless redis_url

    [false, true].each do |clear|
      namespace = unique_redis_namespace
      store = Kemal::Cache::RedisStore.new(redis_url, namespace)
      other_store = Kemal::Cache::RedisStore.new(redis_url, namespace)
      other_config = Kemal::Cache::Config.new(store: other_store)
      entered = Channel(Nil).new
      release = Channel(Nil).new
      done = Channel(HTTP::Client::Response).new
      handler = Kemal::Cache::Handler.new(Kemal::Cache::Config.new(store: store))
      handler.next = CoordinatedResponseHandler.new(entered, release, "old value")
      spawn { done.send(process_request(handler, HTTP::Request.new("GET", "/race"))) }
      entered.receive
      invalidated = clear ? other_config.try_clear_cache : other_config.try_invalidate("/race")
      release.send(nil)
      done.receive.body.should eq("old value")
      invalidated.should be_true
      other_store.get("/race").should be_nil
    ensure
      store.try(&.clear)
    end
  end
end
