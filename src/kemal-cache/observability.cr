module Kemal::Cache
  enum EventType
    Hit
    Miss
    Store
    StoreError
    Bypass
    NotModified
    Invalidate
    Clear
  end

  struct Event
    getter type : EventType
    getter key : String?
    getter path : String?
    getter http_method : String?
    getter status_code : Int32?
    getter detail : String?

    def initialize(
      @type : EventType,
      @key : String? = nil,
      @path : String? = nil,
      @http_method : String? = nil,
      @status_code : Int32? = nil,
      @detail : String? = nil,
    )
    end
  end

  class Stats
    @hits = Atomic(Int64).new(0_i64)
    @misses = Atomic(Int64).new(0_i64)
    @stores = Atomic(Int64).new(0_i64)
    @store_errors = Atomic(Int64).new(0_i64)
    @bypasses = Atomic(Int64).new(0_i64)
    @not_modified = Atomic(Int64).new(0_i64)
    @invalidations = Atomic(Int64).new(0_i64)
    @clears = Atomic(Int64).new(0_i64)

    def record(type : EventType) : Nil
      case type
      when EventType::Hit
        @hits.add(1_i64)
      when EventType::Miss
        @misses.add(1_i64)
      when EventType::Store
        @stores.add(1_i64)
      when EventType::StoreError
        @store_errors.add(1_i64)
      when EventType::Bypass
        @bypasses.add(1_i64)
      when EventType::NotModified
        @not_modified.add(1_i64)
      when EventType::Invalidate
        @invalidations.add(1_i64)
      when EventType::Clear
        @clears.add(1_i64)
      end
    end

    def hits : Int64
      @hits.get
    end

    def misses : Int64
      @misses.get
    end

    def stores : Int64
      @stores.get
    end

    def store_errors : Int64
      @store_errors.get
    end

    def bypasses : Int64
      @bypasses.get
    end

    def not_modified : Int64
      @not_modified.get
    end

    def invalidations : Int64
      @invalidations.get
    end

    def clears : Int64
      @clears.get
    end

    def cacheable_requests : Int64
      hits + misses
    end

    def requests : Int64
      cacheable_requests + bypasses
    end

    def hit_ratio : Float64
      total_cacheable_requests = cacheable_requests
      return 0.0 if total_cacheable_requests.zero?

      hits.to_f / total_cacheable_requests
    end
  end
end
