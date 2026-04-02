module Kemal::Cache
  class Handler < Kemal::Handler
    HEADER_NAME = "X-Kemal-Cache"

    getter config : Config

    def initialize(@config : Config = Config.new)
    end

    def call(context : HTTP::Server::Context)
      return bypass(context) unless cacheable?(context)

      key = cache_key(context)

      if payload = @config.store.get(key)
        write_hit(context, payload)
        return
      end

      write_miss(context, key)
    end

    private def cacheable?(context : HTTP::Server::Context) : Bool
      @config.enabled && context.request.method == "GET"
    end

    private def cache_key(context : HTTP::Server::Context) : String
      context.request.resource
    end

    private def bypass(context : HTTP::Server::Context) : Nil
      context.response.headers[HEADER_NAME] = "MISS"
      call_next(context)
    end

    private def write_hit(context : HTTP::Server::Context, payload : String) : Nil
      cached_response = CachedResponse.from_json(payload)

      context.response.status_code = cached_response.status_code
      context.response.headers.clear
      restore_headers(context.response.headers, cached_response.headers)
      context.response.headers[HEADER_NAME] = "HIT"
      context.response.print cached_response.body
    end

    private def write_miss(context : HTTP::Server::Context, key : String) : Nil
      original_output = context.response.output
      capture_output = CaptureIO.new

      context.response.output = capture_output
      call_next(context)

      body = capture_output.to_s
      payload = CachedResponse.new(
        status_code: context.response.status_code,
        headers: snapshot_headers(context.response.headers),
        body: body
      ).to_json

      @config.store.set(key, payload, @config.expires_in)

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

    private class CaptureIO < IO::Memory
      def close : Nil
      end

      def closed? : Bool
        false
      end
    end
  end
end
