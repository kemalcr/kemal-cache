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
