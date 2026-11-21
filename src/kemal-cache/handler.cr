class HTTP::Server::Response
  # :nodoc:
  def kemal_cache_cookies? : Bool
    jar = @cookies
    !jar.nil? && !jar.empty?
  end

  # :nodoc:
  def kemal_cache_headers_sent? : Bool
    wrote_headers?
  end
end

module Kemal::Cache
  class Handler < Kemal::Handler
    HEADER_NAME                      = "X-Kemal-Cache"
    MAX_AGE                          = 2_147_483_648_i64
    PRIVATE_CACHE_CONTROL_DIRECTIVES = {"no-cache", "no-store", "private"}
    CACHE_CONTROL_DIRECTIVE          = /(?:[^",]+|"(?:[^"\\]|\\.)*")+/

    getter config : Config

    def initialize(@config : Config = Config.new)
      @request_collapser = RequestCollapser.new
    end

    def call(context : HTTP::Server::Context)
      if bypass_reason = request_bypass_reason(context)
        return bypass(context, bypass_reason)
      end

      key = cache_key(context)
      if @config.collapse_concurrent_misses
        call_with_request_collapsing(context, key)
      else
        write_cached_response_or_miss(context, key)
      end
    end

    private def request_bypass_reason(context : HTTP::Server::Context) : String?
      return "disabled" unless @config.enabled
      return "method_not_cacheable" unless @config.cacheable_method?(context.request.method)
      return "skip_if" if @config.skip?(context)
      return "authorization_header" if header_present?(context.request.headers, "authorization")
      headers = context.request.headers
      return "cookie_header" if header_present?(headers, "cookie")
      return "range_header" if headers.has_key?("Range")
      return "upgrade_header" if headers.has_key?("Upgrade")
      return "request_cache_control" if request_requires_origin?(headers)
      return "origin_precondition" if headers.has_key?("If-Match") || headers.has_key?("If-Unmodified-Since")
      if !context.request.method.in?("GET", "HEAD") && (headers.has_key?("If-None-Match") || headers.has_key?("If-Modified-Since"))
        return "conditional_method"
      end

      nil
    end

    private def cache_key(context : HTTP::Server::Context) : String
      @config.cache_key(context)
    end

    private def bypass(context : HTTP::Server::Context, reason : String) : Nil
      context.response.headers[HEADER_NAME] = "MISS"
      @config.observe(EventType::Bypass, context: context, detail: reason)
      call_next(context)
    end

    private def deserialize_cached_response(payload : String, key : String, context : HTTP::Server::Context) : CachedResponse?
      CachedResponse.from_json(payload)
    rescue error : JSON::ParseException | TypeCastError
      safe_store_delete(key, context, "corrupt_payload")
      nil
    end

    private def write_hit(context : HTTP::Server::Context, key : String, cached_response : CachedResponse, body : String) : Nil
      prepare_hit_headers(context.response.headers, cached_response.headers)
      restore_headers(context.response.headers, cached_response.headers)
      if stored_at = cached_response.stored_at
        resident_time = (Time.utc - stored_at).total_seconds.to_i64.clamp(0_i64, MAX_AGE)
        origin_age = (cached_response.origin_age || 0_i64).clamp(0_i64, MAX_AGE)
        context.response.headers["Age"] = {origin_age + resident_time, MAX_AGE}.min.to_s
      end
      if cached_response.status_code == 200 && not_modified?(context.request, cached_response.headers)
        context.response.status_code = 304
        context.response.headers[HEADER_NAME] = "HIT"
        @config.observe(EventType::Hit, key: key, context: context, status_code: 304)
        @config.observe(EventType::NotModified, key: key, context: context, status_code: 304)
        return
      end

      context.response.status_code = cached_response.status_code
      context.response.headers[HEADER_NAME] = "HIT"
      @config.observe(EventType::Hit, key: key, context: context, status_code: cached_response.status_code)
      context.response.print body
    end

    private def prepare_hit_headers(headers : HTTP::Headers, cached_headers : Hash(String, Array(String))) : Nil
      cached_headers.each_key do |name|
        headers.delete(name)
      end

      headers.delete(HEADER_NAME)
      headers.delete("Content-Length")
      headers.delete("Transfer-Encoding")
    end

    private def write_miss(context : HTTP::Server::Context, key : String) : Nil
      response = context.response
      original_output = response.output
      baseline_headers = snapshot_headers(response.headers)
      request_method = context.request.method
      request_headers = {} of String => Array(String)
      context.request.headers.each { |name, values| request_headers[name.downcase] = values.dup }
      store = @config.store
      generation = safe_write_generation(store, key, context)
      forwarding_metadata = nil
      close_stream = false
      before_forward = -> do
        close_stream = context.request.version == "HTTP/1.0" && !response.headers.has_key?("Content-Length")
        response.headers["Connection"] = "close" if close_stream
        nil
      end
      capture_output = CaptureIO.new(original_output, @config.max_body_bytes, @config.cache_streaming, before_forward) do
        if forwarding_metadata.nil? && response.kemal_cache_headers_sent?
          forwarding_metadata = storage_metadata(response)
        end
      end

      response.headers[HEADER_NAME] = "MISS"
      response.output = capture_output
      call_next(context)
      response.output = original_output

      body = capture_output.captured_body
      if body && generation && storable_response?(context) &&
         (forwarding_metadata.nil? || forwarding_metadata == storage_metadata(response))
        ttl = @config.resolve_ttl(context, key)
        stored_at = Time.utc
        origin_age = response_age(response.headers, stored_at)
        if remaining = response_freshness(response.headers, origin_age)
          ttl = remaining if remaining < ttl
        end
        if ttl > 0.seconds
          ensure_cache_validators(response, body) unless capture_output.streaming?
          payload = CachedResponse.new(
            status_code: response.status_code,
            headers: snapshot_response_headers(response.headers, baseline_headers, request_method == "HEAD"),
            body: body,
            request_method: request_method,
            vary_request_headers: snapshot_vary_headers(response.headers, request_headers),
            stored_at: stored_at,
            origin_age: origin_age,
          ).to_json
          safe_store_set(store, key, payload, ttl, generation, context)
        end
      end

      unless capture_output.streaming?
        response.headers[HEADER_NAME] = "MISS"
        response.print body if body
      end
      @config.observe(EventType::Miss, key: key, context: context)
    ensure
      context.response.headers["Connection"] = "close" if close_stream
      context.response.output = original_output.not_nil!
    end

    private def write_cached_response_or_miss(context : HTTP::Server::Context, key : String) : Nil
      return if write_hit_if_present(context, key)

      write_miss(context, key)
    end

    private def write_hit_if_present(context : HTTP::Server::Context, key : String) : Bool
      if payload = safe_store_get(key, context)
        if cached_response = deserialize_cached_response(payload, key, context)
          if cached_response.request_method == context.request.method && vary_matches?(context, cached_response)
            begin
              body = cached_response.body
            rescue Base64::Error
              safe_store_delete(key, context, "corrupt_payload")
              return false
            end
            write_hit(context, key, cached_response, body)
            return true
          end
        end
      end

      false
    end

    private def call_with_request_collapsing(context : HTTP::Server::Context, key : String) : Nil
      loop do
        return if write_hit_if_present(context, key)

        claim = @request_collapser.claim(key)
        if claim.owner?
          begin
            return if write_hit_if_present(context, key)

            write_miss(context, key)
            return
          ensure
            @request_collapser.release(key)
          end
        else
          claim.wait
        end
      end
    end

    private def safe_store_get(key : String, context : HTTP::Server::Context) : String?
      @config.store.get(key)
    rescue error
      observe_store_error("get", key, context, error)
      nil
    end

    private def safe_write_generation(store : Store, key : String, context : HTTP::Server::Context) : String?
      store.write_generation
    rescue error
      observe_store_error("write_generation", key, context, error)
      nil
    end

    private def safe_store_set(store : Store, key : String, payload : String, ttl : Time::Span, generation : String, context : HTTP::Server::Context) : Nil
      if store.set_if_current(key, payload, ttl, generation)
        @config.observe(EventType::Store, key: key, context: context)
      end
    rescue error
      observe_store_error("set", key, context, error)
    end

    private def safe_store_delete(key : String, context : HTTP::Server::Context, detail : String) : Nil
      @config.store.delete(key)
      @config.observe(EventType::Invalidate, key: key, context: context, detail: detail)
    rescue error
      observe_store_error("delete", key, context, error, detail)
    end

    private def observe_store_error(operation : String, key : String, context : HTTP::Server::Context, error : Exception, detail : String? = nil) : Nil
      suffix = detail ? ":#{detail}" : ""
      @config.observe(
        EventType::StoreError,
        key: key,
        context: context,
        detail: "#{operation}#{suffix}:#{error.class.name}"
      )
    end

    private class RequestCollapser
      private struct Claim
        getter owner : Bool

        def initialize(@owner : Bool, @channel : Channel(Nil)? = nil)
        end

        def owner? : Bool
          @owner
        end

        def wait : Nil
          @channel.not_nil!.receive unless @owner
        end
      end

      def initialize
        @mutex = Mutex.new
        @waiters = {} of String => Array(Channel(Nil))
      end

      def claim(key : String) : Claim
        @mutex.synchronize do
          if waiters = @waiters[key]?
            channel = Channel(Nil).new
            waiters << channel
            Claim.new(false, channel)
          else
            @waiters[key] = [] of Channel(Nil)
            Claim.new(true)
          end
        end
      end

      def release(key : String) : Nil
        waiters = @mutex.synchronize do
          @waiters.delete(key) || [] of Channel(Nil)
        end

        waiters.each(&.send(nil))
      end
    end

    private def restore_headers(headers : HTTP::Headers, cached_headers : Hash(String, Array(String))) : Nil
      cached_headers.each do |name, values|
        values.each do |value|
          headers.add(name, value)
        end
      end
    end

    private def snapshot_headers(source : HTTP::Headers) : Hash(String, Array(String))
      headers = {} of String => Array(String)

      source.each do |name, values|
        next if skip_header?(name)
        headers[name] = values.dup
      end

      headers
    end

    private def storage_metadata(response : HTTP::Server::Response)
      {response.status_code, snapshot_headers(response.headers), response.kemal_cache_cookies?}
    end

    private def snapshot_response_headers(source : HTTP::Headers, baseline_headers : Hash(String, Array(String)), head : Bool) : Hash(String, Array(String))
      headers = {} of String => Array(String)

      source.each do |name, values|
        next if skip_header?(name) && !(head && name.compare("Content-Length", case_insensitive: true).zero?)
        next if baseline_headers[name]? == values

        headers[name] = values.dup
      end

      headers
    end

    private def skip_header?(name : String) : Bool
      normalized = name.downcase
      normalized == "content-length" ||
        normalized == "transfer-encoding" ||
        normalized == "connection" ||
        normalized == "keep-alive" ||
        normalized == HEADER_NAME.downcase
    end

    private def storable_response?(context : HTTP::Server::Context) : Bool
      response = context.response

      response.upgrade_handler.nil? &&
        response.status_code != 101 &&
        response.status_code != 206 &&
        !response.headers.has_key?("Content-Range") &&
        @config.cacheable_status_code?(response.status_code) &&
        !header_present?(response.headers, "set-cookie") &&
        !response.kemal_cache_cookies? &&
        !vary_star?(response.headers) &&
        !cache_control_disallows_storage?(response.headers) &&
        @config.should_cache?(context)
    end

    private def ensure_cache_validators(response : HTTP::Server::Response, body : String) : Nil
      unless header_present?(response.headers, "etag") || !@config.auto_etag
        response.headers["ETag"] = %{W/"#{Digest::SHA256.hexdigest(body)}"}
      end

      unless header_present?(response.headers, "last-modified") || !@config.auto_last_modified
        response.headers["Last-Modified"] = HTTP.format_time(Time.utc)
      end
    end

    private def not_modified?(request : HTTP::Request, cached_headers : Hash(String, Array(String))) : Bool
      return false unless @config.conditional_get && request.method.in?("GET", "HEAD")

      if if_none_match = request.if_none_match
        etag = header_value(cached_headers, "etag")
        return true if if_none_match.includes?("*")
        return false unless etag

        if_none_match.any? { |candidate| candidate.lchop("W/") == etag.lchop("W/") }
      elsif if_modified_since = request.headers["If-Modified-Since"]?
        last_modified = header_value(cached_headers, "last-modified")
        return false unless last_modified

        header_time = HTTP.parse_time(if_modified_since)
        last_modified_time = HTTP.parse_time(last_modified)
        !!(header_time && last_modified_time && last_modified_time <= header_time)
      else
        false
      end
    end

    private def header_present?(headers : HTTP::Headers, target_name : String) : Bool
      headers.each do |name, values|
        return true if name.downcase == target_name && !values.empty?
      end

      false
    end

    private def header_value(headers : Hash(String, Array(String)), target_name : String) : String?
      headers.each do |name, values|
        return values.first? if name.downcase == target_name && !values.empty?
      end

      nil
    end

    private def vary_star?(headers : HTTP::Headers) : Bool
      header_tokens(headers, "vary").includes?("*")
    end

    private def snapshot_vary_headers(response_headers : HTTP::Headers, request_headers : Hash(String, Array(String))) : Hash(String, String?)
      headers = {} of String => String?
      header_tokens(response_headers, "vary").each do |name|
        headers[name] = vary_header_digest(request_headers[name]?) unless name.empty?
      end
      headers
    end

    private def vary_header_digest(values : Array(String)?) : String?
      Digest::SHA256.hexdigest(values.to_json) if values
    end

    private def vary_matches?(context : HTTP::Server::Context, cached : CachedResponse) : Bool
      return false unless vary = cached.vary_request_headers
      return false if header_tokens(context.response.headers, "vary").any? { |name| !name.empty? && !vary.has_key?(name) }

      vary.all? { |name, digest| vary_header_digest(context.request.headers.get?(name)) == digest }
    end

    private def cache_control_disallows_storage?(headers : HTTP::Headers) : Bool
      cache_control(headers).any? { |name, _| PRIVATE_CACHE_CONTROL_DIRECTIVES.includes?(name) }
    end

    private def request_requires_origin?(headers : HTTP::Headers) : Bool
      cache_control(headers).any? do |name, value|
        name.in?("no-cache", "no-store") || (name == "max-age" && value.to_u64? == 0_u64)
      end
    end

    private def response_age(headers : HTTP::Headers, received_at : Time) : Int64
      supplied_age = headers["Age"]?.try(&.to_u64?) || 0_u64
      age = {supplied_age, MAX_AGE.to_u64}.min.to_i64
      if date = headers["Date"]?.try { |value| HTTP.parse_time(value) }
        apparent_age = (received_at - date).total_seconds.to_i64
        age = {age, apparent_age.clamp(0_i64, MAX_AGE)}.max
      end
      age
    end

    private def response_freshness(headers : HTTP::Headers, age : Int64) : Time::Span?
      directives = cache_control(headers)
      values = directives.select { |name, _| name == "s-maxage" }
      values = directives.select { |name, _| name == "max-age" } if values.empty?
      return if values.empty?
      return 0.seconds unless values.size == 1 && (seconds = values.first[1].to_u64?)

      seconds = {seconds, MAX_AGE.to_u64}.min.to_i64
      {seconds - age, 0_i64}.max.seconds
    end

    private def cache_control(headers : HTTP::Headers) : Array({String, String})
      directives = [] of {String, String}
      if lines = headers.get?("Cache-Control")
        lines.each do |line|
          line.scan(CACHE_CONTROL_DIRECTIVE) do |field|
            name, _, value = field[0].partition('=')
            directives << {name.strip.downcase, value.strip.strip('"')}
          end
        end
      end
      directives
    end

    private def header_tokens(headers : HTTP::Headers, target_name : String) : Array(String)
      tokens = [] of String

      headers.each do |name, values|
        next unless name.downcase == target_name

        values.each do |value|
          value.split(',').each do |token|
            tokens << token.strip.downcase
          end
        end
      end

      tokens
    end

    private class CaptureIO < IO
      getter? streaming = false

      @capture : IO::Memory? = IO::Memory.new

      def initialize(@output : IO, @max_body_bytes : Int32?, @cache_streaming : Bool, @before_forward : ->, &@after_forward : ->)
      end

      def read(slice : Bytes) : Int32
        @output.read(slice)
      end

      def write(slice : Bytes) : Nil
        if buffer = @capture
          if (limit = @max_body_bytes) && slice.size > limit - buffer.size
            start_stream(keep_capture: false)
            @capture = nil
          else
            buffer.write(slice)
          end
        end

        if @streaming
          @output.write(slice)
          @after_forward.call if @capture
        end
      end

      def captured_body : String?
        @capture.try(&.to_s)
      end

      def flush : Nil
        start_stream(keep_capture: @cache_streaming)
        @output.flush
        @after_forward.call if @capture
      end

      def close : Nil
        start_stream(keep_capture: true)
        @output.close
        @after_forward.call if @capture
      end

      def closed? : Bool
        @output.closed?
      end

      private def start_stream(keep_capture : Bool) : Nil
        return if @streaming

        @streaming = true
        @before_forward.call
        if buffer = @capture
          @output.write(buffer.to_slice)
          @capture = nil unless keep_capture
          @after_forward.call if @capture
        end
      end
    end
  end
end
