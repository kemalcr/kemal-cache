module Kemal::Cache
  class MemoryStore < Store
    getter max_entries : Int32?

    @expirations = [] of {Time, String}

    def initialize(@max_entries : Int32? = nil)
      @entries = {} of String => CacheEntry
      @mutex = Mutex.new
    end

    def get(key : String) : String?
      @mutex.synchronize do
        if entry = @entries[key]?
          if entry.expired?
            @entries.delete(key)
            compact_expirations
            nil
          else
            entry.value
          end
        end
      end
    end

    def set(key : String, value : String, ttl : Time::Span) : Nil
      return if retention_disabled?
      @mutex.synchronize do
        prune_expired_entries(Time.utc)
        evict_oldest_entry if should_evict_before_write?(key)
        entry = CacheEntry.new(value, ttl)
        @entries[key] = entry
        enqueue_expiration({entry.expires_at, key})
        compact_expirations
      end
    end

    def set_if_current(key : String, value : String, ttl : Time::Span, generation : String) : Bool
      return false if retention_disabled?
      super
    end

    def delete(key : String) : Nil
      @mutex.synchronize do
        @entries.delete(key)
        compact_expirations
      end
    end

    def clear : Nil
      @mutex.synchronize do
        @entries.clear
        @expirations.clear
      end
    end

    private def retention_disabled? : Bool
      limit = @max_entries
      !!(limit && limit <= 0)
    end

    private def prune_expired_entries(now : Time) : Nil
      while (scheduled = @expirations.first?) && scheduled[0] <= now
        expires_at, key = scheduled
        remove_first_expiration
        if @entries[key]?.try(&.expires_at) == expires_at
          @entries.delete(key)
        end
      end
    end

    private def enqueue_expiration(item : {Time, String}) : Nil
      index = @expirations.size
      @expirations << item
      while index > 0
        parent = (index - 1) // 2
        break if @expirations[parent][0] <= item[0]
        @expirations[index] = @expirations[parent]
        index = parent
      end
      @expirations[index] = item
    end

    private def remove_first_expiration : Nil
      item = @expirations.pop
      return if @expirations.empty?

      index = 0
      while (child = index * 2 + 1) < @expirations.size
        right = child + 1
        if right < @expirations.size && @expirations[right][0] < @expirations[child][0]
          child = right
        end
        break if item[0] <= @expirations[child][0]
        @expirations[index] = @expirations[child]
        index = child
      end
      @expirations[index] = item
    end

    private def compact_expirations : Nil
      # Replaced and evicted entries leave stale timestamps in the heap.
      return unless @entries.empty? || @expirations.size > @entries.size.to_i64 * 2 + 32
      @expirations.clear
      @entries.each { |key, entry| enqueue_expiration({entry.expires_at, key}) }
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
