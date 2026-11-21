require "random/secure"

module Kemal::Cache
  class RedisStore < Store
    DEFAULT_NAMESPACE = "kemal-cache"
    CLEAR_BATCH_SIZE  = 1000
    GENERATION_TTL    = 24.hours

    module Client
      abstract def get(key : String)
      abstract def set(key : String, value : String, *, ex : Time::Span, nx = false, xx = false, keepttl = false, get = false)
      abstract def del(*keys : String)
      abstract def del(keys : Enumerable(String))
      abstract def scan_each(match pattern : String? = nil, count : String | Int | Nil = nil, type : String? = nil, & : String ->) : Nil
    end

    private class RedisClientAdapter
      include Client

      def initialize(@client : Redis::Client)
      end

      def get(key : String)
        @client.get(key)
      end

      def set(key : String, value : String, *, ex : Time::Span, nx = false, xx = false, keepttl = false, get = false)
        @client.set(key, value, ex: ex, nx: nx, xx: xx, keepttl: keepttl, get: get)
      end

      def del(*keys : String)
        @client.del(*keys)
      end

      def del(keys : Enumerable(String))
        @client.del(keys)
      end

      def scan_each(match pattern : String? = nil, count : String | Int | Nil = nil, type : String? = nil, & : String ->) : Nil
        cursor = "0"
        loop do
          page = @client.scan(cursor, match: pattern, count: count, type: type).as(Array)
          cursor = page[0].as(String)
          page[1].as(Array).each { |key| yield key.as(String) }
          break if cursor == "0"
        end
      end

      def write_generation(key : String) : String
        if generation = @client.get(key)
          return generation.as(String)
        end

        @client.eval(<<-LUA, keys: [key], args: [Random::Secure.hex(16), GENERATION_TTL.total_seconds.to_i64.to_s]).as(String)
          local current = redis.call("GET", KEYS[1])
          if current then return current end
          redis.call("SET", KEYS[1], ARGV[1], "EX", ARGV[2])
          return ARGV[1]
          LUA
      end

      def set_if_current(key : String, generation_key : String, value : String, ttl : Time::Span, generation : String) : Bool
        @client.eval(<<-LUA, keys: [key, generation_key], args: [value, ttl.total_milliseconds.to_i64.to_s, generation]) == 1_i64
          if redis.call("GET", KEYS[2]) ~= ARGV[3] then return 0 end
          redis.call("SET", KEYS[1], ARGV[1], "PX", ARGV[2])
          return 1
          LUA
      end

      def delete_and_rotate(key : String, generation_key : String) : Nil
        @client.eval(<<-LUA, keys: [key, generation_key], args: [Random::Secure.hex(16), GENERATION_TTL.total_seconds.to_i64.to_s])
          redis.call("SET", KEYS[2], ARGV[1], "EX", ARGV[2])
          return redis.call("DEL", KEYS[1])
          LUA
        nil
      end

      def rotate_generation(key : String) : Nil
        @client.set(key, Random::Secure.hex(16), ex: GENERATION_TTL)
        nil
      end
    end

    getter client : Client
    getter namespace : String

    def initialize(@client : Client = RedisClientAdapter.new(Redis::Client.new), @namespace : String = DEFAULT_NAMESPACE)
    end

    def initialize(uri : URI, @namespace : String = DEFAULT_NAMESPACE)
      @client = RedisClientAdapter.new(Redis::Client.new(uri))
    end

    def initialize(url : String, @namespace : String = DEFAULT_NAMESPACE)
      @client = RedisClientAdapter.new(Redis::Client.new(URI.parse(url)))
    end

    def self.from_env(env_var : String = "REDIS_URL", namespace : String = DEFAULT_NAMESPACE) : self
      new(RedisClientAdapter.new(Redis::Client.from_env(env_var)), namespace)
    end

    def get(key : String) : String?
      @client.get(namespaced_key(key)).try(&.as(String))
    end

    def set(key : String, value : String, ttl : Time::Span) : Nil
      @client.set(namespaced_key(key), value, ex: redis_ttl(ttl))
      nil
    end

    def write_generation : String
      if client = @client.as?(RedisClientAdapter)
        client.write_generation(generation_key)
      else
        super
      end
    end

    def set_if_current(key : String, value : String, ttl : Time::Span, generation : String) : Bool
      if client = @client.as?(RedisClientAdapter)
        client.set_if_current(namespaced_key(key), generation_key, value, redis_ttl(ttl), generation)
      else
        super
      end
    end

    def delete(key : String) : Nil
      if client = @client.as?(RedisClientAdapter)
        client.delete_and_rotate(namespaced_key(key), generation_key)
      else
        @client.del(namespaced_key(key))
      end
      nil
    end

    def clear : Nil
      keys_to_delete = [] of String

      if client = @client.as?(RedisClientAdapter)
        client.rotate_generation(generation_key)
      end

      @client.scan_each(match: "#{entry_prefix}*") do |key|
        keys_to_delete << key
        flush_delete_batch(keys_to_delete) if keys_to_delete.size >= CLEAR_BATCH_SIZE
      end

      flush_delete_batch(keys_to_delete)
      nil
    end

    private def namespaced_key(key : String) : String
      "#{entry_prefix}#{key}"
    end

    private getter entry_prefix : String { "#{namespace_prefix}entry:" }
    private getter generation_key : String { "#{namespace_prefix}generation" }
    private getter namespace_prefix : String { "kemal-cache-v2:#{Base64.urlsafe_encode(namespace, padding: false)}:" }

    private def redis_ttl(ttl : Time::Span) : Time::Span
      0.seconds < ttl < 1.millisecond ? 1.millisecond : ttl
    end

    private def flush_delete_batch(keys : Array(String)) : Nil
      return if keys.empty?

      @client.del(keys)
      keys.clear
    end
  end
end
