require "kemal"
require "digest/sha256"
require "redis"
require "./kemal-cache/store"
require "./kemal-cache/cache_entry"
require "./kemal-cache/cached_response"
require "./kemal-cache/memory_store"
require "./kemal-cache/redis_store"
require "./kemal-cache/config"
require "./kemal-cache/handler"

module Kemal::Cache
end
