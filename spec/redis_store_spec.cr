require "./spec_helper"

describe Kemal::Cache::RedisStore do
  it "stores, deletes, clears, and expires values within its namespace" do
    client = FakeRedisClient.new
    store = Kemal::Cache::RedisStore.new(client, "spec-cache")

    store.set("greeting", "hello", 20.milliseconds)
    store.get("greeting").should eq("hello")

    store.delete("greeting")
    store.get("greeting").should be_nil

    store.set("one", "1", 20.milliseconds)
    store.set("two", "2", 20.milliseconds)
    client.set("other-cache:keep", "3", ex: 20.milliseconds)
    store.clear

    store.get("one").should be_nil
    store.get("two").should be_nil
    client.get("other-cache:keep").should eq("3")

    store.set("short", "ttl", 5.milliseconds)
    sleep 10.milliseconds
    store.get("short").should be_nil
  end
end
