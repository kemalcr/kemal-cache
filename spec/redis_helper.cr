require "./spec_helper"
require "../src/kemal-cache/redis"

struct FakeRedisEntry
  getter value : String
  getter expires_at : Time

  def initialize(@value : String, ttl : Time::Span)
    @expires_at = Time.utc + ttl
  end

  def expired?(now : Time = Time.utc) : Bool
    @expires_at <= now
  end
end

class FakeRedisClient
  include Kemal::Cache::RedisStore::Client

  getter last_scan_pattern : String?

  def initialize
    @entries = {} of String => FakeRedisEntry
  end

  def get(key : String)
    if entry = @entries[key]?
      if entry.expired?
        @entries.delete(key)
        nil
      else
        entry.value
      end
    end
  end

  def set(key : String, value : String, *, ex : Time::Span, nx = false, xx = false, keepttl = false, get = false)
    @entries[key] = FakeRedisEntry.new(value, ex)
    "OK"
  end

  def del(*keys : String)
    deleted = 0

    keys.each do |key|
      deleted += 1 if @entries.delete(key)
    end

    deleted.to_i64
  end

  def del(keys : Enumerable(String))
    deleted = 0

    keys.each do |key|
      deleted += 1 if @entries.delete(key)
    end

    deleted.to_i64
  end

  def scan_each(match pattern : String? = nil, count : String | Int | Nil = nil, type : String? = nil, & : String ->) : Nil
    @last_scan_pattern = pattern
    prefix = pattern.try(&.ends_with?("*")) ? pattern.not_nil!.rchop("*") : pattern

    @entries.keys.each do |key|
      next if prefix && !key.starts_with?(prefix)
      yield key
    end
  end
end

def real_redis_url : String?
  ENV["REDIS_URL"]?
end

def unique_redis_namespace(prefix : String = "kemal-cache-spec") : String
  "#{prefix}-#{Random.rand(1_000_000)}-#{Time.utc.to_unix_ms}"
end
