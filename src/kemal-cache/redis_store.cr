module Kemal::Cache
  class RedisStore < Store
    DEFAULT_NAMESPACE = "kemal-cache"

    module Client
      abstract def get(key : String)
      abstract def set(key : String, value : String, *, ex : Time::Span, nx = false, xx = false, keepttl = false, get = false)
      abstract def del(*keys : String)
      abstract def del(keys : Enumerable(String))
      abstract def keys(pattern = "*")
    end

    getter client : Client
    getter namespace : String

    def initialize(@client : Client = Redis::Client.new, @namespace : String = DEFAULT_NAMESPACE)
    end

    def initialize(uri : URI, @namespace : String = DEFAULT_NAMESPACE)
      @client = Redis::Client.new(uri)
    end

    def initialize(url : String, @namespace : String = DEFAULT_NAMESPACE)
      @client = Redis::Client.new(URI.parse(url))
    end

    def self.from_env(env_var : String = "REDIS_URL", namespace : String = DEFAULT_NAMESPACE) : self
      new(Redis::Client.from_env(env_var), namespace)
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
      keys = @client.keys("#{namespace}:*")
      return unless keys.is_a?(Array)

      namespaced_keys = keys.compact_map(&.as?(String))
      return if namespaced_keys.empty?

      @client.del(namespaced_keys)
      nil
    end

    private def namespaced_key(key : String) : String
      "#{namespace}:#{key}"
    end
  end
end

class Redis::Client
  include Kemal::Cache::RedisStore::Client
end
