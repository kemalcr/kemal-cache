module Kemal::Cache
  class Config
    DEFAULT_CACHEABLE_STATUS_CODES = (200..299).to_a
    DEFAULT_MAX_BODY_BYTES         = 1_048_576
    alias TTLResolver = Proc(HTTP::Server::Context, String, Time::Span?)

    property expires_in : Time::Span
    property store : Store
    property enabled : Bool
    property key_generator : Proc(HTTP::Server::Context, String)?
    property skip_if : Proc(HTTP::Server::Context, Bool)?
    property should_cache : Proc(HTTP::Server::Context, Bool)?
    property max_body_bytes : Int32?
    property cache_streaming : Bool
    property auto_etag : Bool
    property auto_last_modified : Bool
    property conditional_get : Bool
    property stats : Stats
    property on_event : Proc(Event, Nil)?
    getter cacheable_methods : Array(String)
    getter cacheable_status_codes : Array(Int32)?

    def initialize(
      @expires_in : Time::Span = 10.minutes,
      @store : Store = MemoryStore.new,
      @enabled : Bool = true,
      @key_generator : Proc(HTTP::Server::Context, String)? = nil,
      ttl_resolver : TTLResolver? = nil,
      @skip_if : Proc(HTTP::Server::Context, Bool)? = nil,
      @should_cache : Proc(HTTP::Server::Context, Bool)? = nil,
      @max_body_bytes : Int32? = DEFAULT_MAX_BODY_BYTES,
      @cache_streaming : Bool = false,
      @auto_etag : Bool = true,
      @auto_last_modified : Bool = true,
      @conditional_get : Bool = true,
      @stats : Stats = Stats.new,
      @on_event : Proc(Event, Nil)? = nil,
      cacheable_methods : Array(String) = ["GET"],
      cacheable_status_codes : Array(Int32)? = DEFAULT_CACHEABLE_STATUS_CODES,
    )
      @ttl_resolver = ttl_resolver
      @cacheable_methods = cacheable_methods.map(&.upcase).uniq
      @cacheable_status_codes = cacheable_status_codes.try(&.uniq)
    end

    def storage_type : Store
      @store
    end

    def storage_type=(store : Store) : Store
      @store = store
    end

    def cacheable_methods=(methods : Array(String)) : Array(String)
      @cacheable_methods = methods.map(&.upcase).uniq
    end

    def cacheable_status_codes=(status_codes : Array(Int32)?) : Array(Int32)?
      @cacheable_status_codes = status_codes.try(&.uniq)
    end

    def cache_key(context : HTTP::Server::Context) : String
      @key_generator.try(&.call(context)) || context.request.resource
    end

    def ttl_resolver : TTLResolver?
      @ttl_resolver
    end

    def ttl_resolver=(resolver : TTLResolver?) : TTLResolver?
      @ttl_resolver = resolver
    end

    def resolve_ttl(context : HTTP::Server::Context, key : String) : Time::Span
      ttl = @ttl_resolver.try(&.call(context, key)) || @expires_in
      raise ArgumentError.new("TTL must be positive") unless ttl > 0.seconds

      ttl
    end

    def invalidate(key : String) : Nil
      @store.delete(key)
      observe(EventType::Invalidate, key: key)
    end

    def try_invalidate(key : String) : Bool
      @store.delete(key)
      observe(EventType::Invalidate, key: key)
      true
    rescue error
      observe_store_error("delete", key: key, error: error)
      false
    end

    def invalidate(context : HTTP::Server::Context) : Nil
      key = cache_key(context)
      @store.delete(key)
      observe(EventType::Invalidate, key: key, context: context)
    end

    def try_invalidate(context : HTTP::Server::Context) : Bool
      key = cache_key(context)
      @store.delete(key)
      observe(EventType::Invalidate, key: key, context: context)
      true
    rescue error
      observe_store_error("delete", key: key, context: context, error: error)
      false
    end

    def clear_cache : Nil
      @store.clear
      observe(EventType::Clear)
    end

    def try_clear_cache : Bool
      @store.clear
      observe(EventType::Clear)
      true
    rescue error
      observe_store_error("clear", error: error)
      false
    end

    def cacheable_method?(method : String) : Bool
      @cacheable_methods.includes?(method.upcase)
    end

    def cacheable_status_code?(status_code : Int32) : Bool
      @cacheable_status_codes.try(&.includes?(status_code)) != false
    end

    def skip?(context : HTTP::Server::Context) : Bool
      @skip_if.try(&.call(context)) || false
    end

    def should_cache?(context : HTTP::Server::Context) : Bool
      @should_cache.try(&.call(context)) != false
    end

    def body_within_limit?(bytesize : Int32) : Bool
      @max_body_bytes.try { |limit| bytesize <= limit } != false
    end

    def observe(
      type : EventType,
      *,
      key : String? = nil,
      context : HTTP::Server::Context? = nil,
      status_code : Int32? = nil,
      detail : String? = nil,
    ) : Nil
      @stats.record(type)
      @on_event.try(&.call(Event.new(
        type,
        key: key,
        path: context.try(&.request.resource),
        http_method: context.try(&.request.method),
        status_code: status_code || context.try(&.response.status_code),
        detail: detail,
      )))
    end

    private def observe_store_error(operation : String, *, key : String? = nil, context : HTTP::Server::Context? = nil, error : Exception) : Nil
      observe(
        EventType::StoreError,
        key: key,
        context: context,
        detail: "#{operation}:#{error.class.name}"
      )
    end
  end
end
