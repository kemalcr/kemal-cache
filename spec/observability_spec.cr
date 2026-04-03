require "./spec_helper"

describe Kemal::Cache::Stats do
  it "tracks event counters and derived totals" do
    stats = Kemal::Cache::Stats.new

    stats.record(Kemal::Cache::EventType::Miss)
    stats.record(Kemal::Cache::EventType::Hit)
    stats.record(Kemal::Cache::EventType::Hit)
    stats.record(Kemal::Cache::EventType::Bypass)
    stats.record(Kemal::Cache::EventType::NotModified)
    stats.record(Kemal::Cache::EventType::Invalidate)
    stats.record(Kemal::Cache::EventType::Clear)

    stats.misses.should eq(1)
    stats.hits.should eq(2)
    stats.bypasses.should eq(1)
    stats.not_modified.should eq(1)
    stats.invalidations.should eq(1)
    stats.clears.should eq(1)
    stats.cacheable_requests.should eq(3)
    stats.requests.should eq(4)
    stats.hit_ratio.should eq(2.0 / 3.0)
  end

  it "returns zero hit ratio with no cacheable requests" do
    stats = Kemal::Cache::Stats.new

    stats.record(Kemal::Cache::EventType::Bypass)

    stats.cacheable_requests.should eq(0)
    stats.requests.should eq(1)
    stats.hit_ratio.should eq(0.0)
  end
end

describe Kemal::Cache::Event do
  it "captures optional event metadata" do
    event = Kemal::Cache::Event.new(
      Kemal::Cache::EventType::Bypass,
      key: "/articles",
      path: "/articles?page=2",
      http_method: "GET",
      status_code: 200,
      detail: "disabled"
    )

    event.type.should eq(Kemal::Cache::EventType::Bypass)
    event.key.should eq("/articles")
    event.path.should eq("/articles?page=2")
    event.http_method.should eq("GET")
    event.status_code.should eq(200)
    event.detail.should eq("disabled")
  end
end
