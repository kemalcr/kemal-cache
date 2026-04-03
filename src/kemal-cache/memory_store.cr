module Kemal::Cache
  class MemoryStore < Store
    getter max_entries : Int32?

    def initialize(@max_entries : Int32? = nil)
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
        evict_oldest_entry if should_evict_before_write?(key)
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

    private def should_evict_before_write?(key : String) : Bool
      limit = @max_entries
      return false unless limit

      !@entries.has_key?(key) && @entries.size >= limit
    end

    private def evict_oldest_entry : Nil
      @entries.shift? if @entries.any?
    end
  end
end
