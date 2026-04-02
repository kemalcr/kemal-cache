module Kemal::Cache
  class Handler < Kemal::Handler
    HEADER_NAME                      = "X-Kemal-Cache"
    PRIVATE_CACHE_CONTROL_DIRECTIVES = {"no-cache", "no-store", "private"}

    getter config : Config

    def initialize(@config : Config = Config.new)
    end

    def call(context : HTTP::Server::Context)
      return bypass(context) unless request_cacheable?(context)

      key = cache_key(context)

      if payload = @config.store.get(key)
        write_hit(context, payload)
        return
      end

      write_miss(context, key)
    end

    private def request_cacheable?(context : HTTP::Server::Context) : Bool
      @config.cacheable_method?(context.request.method) &&
        !@config.skip?(context) &&
        !header_present?(context.request.headers, "authorization") &&
        !header_present?(context.request.headers, "cookie")
    end

    private def cache_key(context : HTTP::Server::Context) : String
      @config.cache_key(context)
    end

    private def bypass(context : HTTP::Server::Context) : Nil
      context.response.headers[HEADER_NAME] = "MISS"
      call_next(context)
    end

    private def write_hit(context : HTTP::Server::Context, payload : String) : Nil
      cached_response = CachedResponse.from_json(payload)

      context.response.headers.clear
      restore_headers(context.response.headers, cached_response.headers)
      if not_modified?(context.request, cached_response.headers)
        context.response.status_code = 304
        context.response.headers[HEADER_NAME] = "HIT"
        return
      end

      context.response.status_code = cached_response.status_code
      context.response.headers[HEADER_NAME] = "HIT"
      context.response.print cached_response.body
    end

    private def write_miss(context : HTTP::Server::Context, key : String) : Nil
      original_output = context.response.output
      capture_output = CaptureIO.new

      context.response.output = capture_output
      call_next(context)

      body = capture_output.to_s
      should_store = storable_response?(context, capture_output, body)
      ensure_cache_validators(context.response, body) if should_store
      payload = CachedResponse.new(
        status_code: context.response.status_code,
        headers: snapshot_headers(context.response.headers),
        body: body
      ).to_json

      if should_store
        @config.store.set(key, payload, @config.expires_in)
      end

      context.response.output = original_output
      context.response.headers[HEADER_NAME] = "MISS"
      context.response.print body
    ensure
      context.response.output = original_output.not_nil!
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

    private def skip_header?(name : String) : Bool
      normalized = name.downcase
      normalized == "content-length" ||
        normalized == "transfer-encoding" ||
        normalized == HEADER_NAME.downcase
    end

    private def storable_response?(context : HTTP::Server::Context, capture_output : CaptureIO, body : String) : Bool
      response = context.response

      @config.cacheable_status_code?(response.status_code) &&
        @config.body_within_limit?(body.bytesize) &&
        (@config.cache_streaming || !capture_output.flushed) &&
        !header_present?(response.headers, "set-cookie") &&
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
      return false unless @config.conditional_get

      if if_none_match = request.if_none_match
        etag = header_value(cached_headers, "etag")
        return false unless etag

        if_none_match.any? { |candidate| candidate == "*" || candidate == etag }
      elsif if_modified_since = request.headers["If-Modified-Since"]?
        last_modified = header_value(cached_headers, "last-modified")
        return false unless last_modified

        header_time = HTTP.parse_time(if_modified_since)
        last_modified_time = HTTP.parse_time(last_modified)
        !!(header_time && last_modified_time && last_modified_time <= header_time + 1.second)
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

    private def cache_control_disallows_storage?(headers : HTTP::Headers) : Bool
      header_tokens(headers, "cache-control").any? do |directive|
        PRIVATE_CACHE_CONTROL_DIRECTIVES.includes?(directive.split('=', 2).first)
      end
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

    private class CaptureIO < IO::Memory
      getter flushed = false

      def flush : Nil
        @flushed = true
      end

      def close : Nil
      end

      def closed? : Bool
        false
      end
    end
  end
end
