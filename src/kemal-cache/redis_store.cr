module Kemal::Cache
  class RedisStore < Store
    DEFAULT_NAMESPACE = "kemal-cache"
    CLEAR_BATCH_SIZE  = 1000

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
        @client.scan_each(match: pattern, count: count, type: type) do |key|
          yield key
        end
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
      @client.set(namespaced_key(key), value, ex: ttl)
      nil
    end

    def delete(key : String) : Nil
      @client.del(namespaced_key(key))
      nil
    end

    def clear : Nil
      keys_to_delete = [] of String

      @client.scan_each(match: "#{namespace}:*") do |key|
        keys_to_delete << key
        flush_delete_batch(keys_to_delete) if keys_to_delete.size >= CLEAR_BATCH_SIZE
      end

      flush_delete_batch(keys_to_delete)
      nil
    end

    private def namespaced_key(key : String) : String
      "#{namespace}:#{key}"
    end

    private def flush_delete_batch(keys : Array(String)) : Nil
      return if keys.empty?

      @client.del(keys)
      keys.clear
    end
  end
end
