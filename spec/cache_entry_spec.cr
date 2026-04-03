require "./spec_helper"

describe Kemal::Cache::CacheEntry do
  it "stores the value and expiration timestamp" do
    before = Time.utc
    entry = Kemal::Cache::CacheEntry.new("hello", 20.milliseconds)
    after = Time.utc

    entry.value.should eq("hello")
    entry.expires_at.should be >= before
    entry.expires_at.should be <= after + 20.milliseconds
  end

  it "reports expiration against a supplied time" do
    entry = Kemal::Cache::CacheEntry.new("hello", 10.milliseconds)

    entry.expired?(entry.expires_at - 1.millisecond).should be_false
    entry.expired?(entry.expires_at).should be_true
    entry.expired?(entry.expires_at + 1.millisecond).should be_true
  end
end
