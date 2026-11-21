module Kemal::Cache
  abstract class Store
    @generation_lock = Mutex.new
    @generation = 0_u64

    abstract def get(key : String) : String?
    abstract def set(key : String, value : String, ttl : Time::Span) : Nil
    abstract def delete(key : String) : Nil
    abstract def clear : Nil

    # Capture before calling the origin. The store compares the generation
    # again when writing so an invalidation can discard the pending fill.
    def write_generation : String
      @generation_lock.synchronize { @generation.to_s }
    end

    def set_if_current(key : String, value : String, ttl : Time::Span, generation : String) : Bool
      @generation_lock.synchronize do
        return false unless generation == @generation.to_s
        set(key, value, ttl)
        true
      end
    end

    def invalidate(key : String) : Nil
      @generation_lock.synchronize do
        delete(key)
        @generation &+= 1
      end
    end

    def invalidate_all : Nil
      @generation_lock.synchronize do
        clear
        @generation &+= 1
      end
    end
  end
end
