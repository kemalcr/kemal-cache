module Kemal::Cache
  class Config
    DEFAULT_CACHEABLE_STATUS_CODES = (200..299).to_a

    property expires_in : Time::Span
    property store : Store
    property enabled : Bool
    property key_generator : Proc(HTTP::Server::Context, String)?
    property skip_if : Proc(HTTP::Server::Context, Bool)?
    property should_cache : Proc(HTTP::Server::Context, Bool)?
    getter cacheable_methods : Array(String)
    getter cacheable_status_codes : Array(Int32)?

    def initialize(
      @expires_in : Time::Span = 10.minutes,
      @store : Store = MemoryStore.new,
      @enabled : Bool = true,
      @key_generator : Proc(HTTP::Server::Context, String)? = nil,
      @skip_if : Proc(HTTP::Server::Context, Bool)? = nil,
      @should_cache : Proc(HTTP::Server::Context, Bool)? = nil,
      cacheable_methods : Array(String) = ["GET"],
      cacheable_status_codes : Array(Int32)? = DEFAULT_CACHEABLE_STATUS_CODES,
    )
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

    def cacheable_method?(method : String) : Bool
      @enabled && @cacheable_methods.includes?(method.upcase)
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
  end
end
