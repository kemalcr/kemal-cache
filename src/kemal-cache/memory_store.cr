module Kemal::Cache
  class MemoryStore < Store
    def initialize
      @entries = {} of String => CacheEntry
      @mutex = Mutex.new
    end

    def get(key : String) : String?
      @mutex.synchronize do
        if entry = @entries[key]?
          if entry.expired?
            @entries.delete(key)
            nil
          else
            entry.value
          end
        end
      end
    end

    def set(key : String, value : String, ttl : Time::Span) : Nil
      @mutex.synchronize do
        @entries[key] = CacheEntry.new(value, ttl)
      end
    end

    def delete(key : String) : Nil
      @mutex.synchronize do
        @entries.delete(key)
      end
    end

    def clear : Nil
      @mutex.synchronize do
        @entries.clear
      end
    end
  end
end
