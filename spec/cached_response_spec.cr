require "./spec_helper"

describe Kemal::Cache::CachedResponse do
  it "serializes and deserializes cached payloads" do
    cached_response = Kemal::Cache::CachedResponse.new(
      status_code: 202,
      headers: {
        "Content-Type"  => ["application/json"],
        "Cache-Control" => ["public", "max-age=60"],
      },
      body: %({"ok":true})
    )

    restored = Kemal::Cache::CachedResponse.from_json(cached_response.to_json)

    restored.status_code.should eq(202)
    restored.headers.should eq(
      {
        "Content-Type"  => ["application/json"],
        "Cache-Control" => ["public", "max-age=60"],
      }
    )
    restored.body.should eq(%({"ok":true}))
  end

  it "raises for invalid payloads" do
    expect_raises(JSON::ParseException | JSON::SerializableError) do
      Kemal::Cache::CachedResponse.from_json(%({"status_code":"bad"}))
    end
  end
end
