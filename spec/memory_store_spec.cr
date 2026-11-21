require "./spec_helper"

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

  it "evicts the oldest entry when max_entries is reached" do
    store = Kemal::Cache::MemoryStore.new(max_entries: 2)

    store.set("one", "1", 20.milliseconds)
    store.set("two", "2", 20.milliseconds)
    store.set("three", "3", 20.milliseconds)

    store.get("one").should be_nil
    store.get("two").should eq("2")
    store.get("three").should eq("3")
  end
end

describe Kemal::Cache::MemoryStore do
  it "reclaims expired entries before capacity eviction" do
    store = Kemal::Cache::MemoryStore.new(max_entries: 2)
    store.set("live", "keep", 1.minute)
    store.set("expired", "stale", 0.seconds)
    store.set("new", "new", 1.minute)
    store.get("live").should eq("keep")
    store.get("expired").should be_nil
    store.get("new").should eq("new")
  end

  it "retains no values at capacity zero" do
    store = Kemal::Cache::MemoryStore.new(max_entries: 0)
    store.set("key", "value", 1.minute)
    store.get("key").should be_nil
  end

  it "ignores an old expiry after the same key is replaced" do
    store = Kemal::Cache::MemoryStore.new
    store.set("key", "initial", 5.milliseconds)
    store.set("key", "replacement", 1.minute)
    sleep 10.milliseconds
    store.set("other", "new", 1.minute)
    store.get("key").should eq("replacement")
  end
end
