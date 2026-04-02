module Kemal::Cache
  struct CacheEntry
    getter value : String
    getter expires_at : Time

    def initialize(@value : String, ttl : Time::Span)
      @expires_at = Time.utc + ttl
    end

    def expired?(now : Time = Time.utc) : Bool
      @expires_at <= now
    end
  end
end
