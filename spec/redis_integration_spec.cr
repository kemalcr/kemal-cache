require "./spec_helper"

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

      store.set("greeting", "hello", 50.milliseconds)
      store.get("greeting").should eq("hello")

      store.delete("greeting")
      store.get("greeting").should be_nil

      store.set("one", "1", 50.milliseconds)
      store.set("two", "2", 50.milliseconds)
      client.set("#{other_namespace}:keep", "3", ex: 50.milliseconds)
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
