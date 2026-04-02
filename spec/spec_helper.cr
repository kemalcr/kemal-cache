require "spec"
require "spec-kemal"
require "../src/kemal-cache"

Spec.before_each do
  Kemal.config.env = "test"
  Kemal.config.always_rescue = false
end

Spec.after_each do
  Kemal.config.clear
end

class RequestState
  property calls : Int32

  def initialize
    @calls = 0
  end
end

class RecordingStore < Kemal::Cache::Store
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

  def keys(pattern = "*")
    prefix = pattern.ends_with?("*") ? pattern.rchop("*") : pattern
    @entries.keys.select(&.starts_with?(prefix))
  end
end

def mount_cache(config : Kemal::Cache::Config = Kemal::Cache::Config.new, &)
  use Kemal::Cache::Handler.new(config)
  yield
  Kemal.config.setup
end
