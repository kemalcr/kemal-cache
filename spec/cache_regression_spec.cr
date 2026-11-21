require "./spec_helper"

describe Kemal::Cache::Handler do
  it "preserves binary bytes on a hit" do
    body = Bytes[0x00, 0xff, 0x80, 0x61]
    mount_cache { get("/binary") { |env| env.response.write(body) } }

    get "/binary"
    response.body.to_slice.should eq(body)
    get "/binary"
    response.headers["X-Kemal-Cache"].should eq("HIT")
    response.body.to_slice.should eq(body)
  end

  it "bypasses ranges and does not cache partial responses" do
    mount_cache do
      get "/download" do |env|
        if env.request.headers.has_key?("Range") || env.params.query.has_key?("partial")
          env.response.status_code = 206
          env.response.headers["Content-Range"] = "bytes 0-1/6"
          "ab"
        else
          "abcdef"
        end
      end
    end

    get "/download", headers: HTTP::Headers{"Range" => "bytes=0-1"}
    response.status_code.should eq(206)
    get "/download"
    response.status_code.should eq(200)
    response.body.should eq("abcdef")

    get "/download", headers: HTTP::Headers{"Range" => "bytes=0-1"}
    response.status_code.should eq(206)
    response.body.should eq("ab")

    2.times do
      get "/download?partial=1"
      response.headers["X-Kemal-Cache"].should eq("MISS")
    end
  end

  it "isolates cached GET and POST responses at the same resource" do
    config = Kemal::Cache::Config.new(cacheable_methods: ["GET", "POST"])
    mount_cache(config) do
      get("/method") { "GET response" }
      post("/method") { "POST response" }
    end

    get "/method"
    post "/method"
    response.headers["X-Kemal-Cache"].should eq("MISS")
    response.body.should eq("POST response")

    post "/method"
    response.headers["X-Kemal-Cache"].should eq("HIT")
    response.body.should eq("POST response")
    get "/method"
    response.headers["X-Kemal-Cache"].should eq("HIT")
    response.body.should eq("GET response")
  end

  it "treats absent and empty Vary request headers as distinct" do
    mount_cache do
      get "/locale" do |env|
        env.response.headers["Vary"] = "Accept-Language"
        env.request.headers["Accept-Language"]? || "(absent)"
      end
    end

    get "/locale", headers: HTTP::Headers{"Accept-Language" => "ko"}
    get "/locale", headers: HTTP::Headers{"Accept-Language" => "en"}
    response.body.should eq("en")
    get "/locale", headers: HTTP::Headers{"Accept-Language" => "en"}
    response.headers["X-Kemal-Cache"].should eq("HIT")
    get "/locale"
    response.body.should eq("(absent)")
    get "/locale", headers: HTTP::Headers{"Accept-Language" => ""}
    response.body.should eq("")
  end

  it "forwards flushes before the route returns with or without streaming storage" do
    [false, true].each do |cache_streaming|
      flushed = Channel(Nil).new
      release = Channel(Nil).new
      done = Channel(Exception?).new
      output = IO::Memory.new
      response = HTTP::Server::Response.new(output)
      config = Kemal::Cache::Config.new(cache_streaming: cache_streaming)
      handler = Kemal::Cache::Handler.new(config)
      handler.next = ->(ctx : HTTP::Server::Context) {
        ctx.response.print "first chunk"
        ctx.response.flush
        flushed.send(nil)
        release.receive
        ctx.response.print "second chunk"
        nil
      }
      spawn do
        begin
          handler.call(HTTP::Server::Context.new(HTTP::Request.new("GET", "/events"), response))
          response.close
          done.send(nil)
        rescue ex
          done.send(ex)
        end
      end
      flushed.receive
      before_release = output.to_s.includes?("first chunk")
      release.send(nil)
      if ex = done.receive
        raise ex
      end
      before_release.should be_true
      output.to_s.should contain("second chunk")
      config.stats.stores.should eq(cache_streaming ? 1 : 0)
    end
  end

  it "sends over-limit responses before the route returns and skips storage" do
    config = Kemal::Cache::Config.new(max_body_bytes: 4, cache_streaming: true)
    output = IO::Memory.new
    response = HTTP::Server::Response.new(output)
    handler = Kemal::Cache::Handler.new(config)
    handler.next = ->(ctx : HTTP::Server::Context) {
      ctx.response.print "123"
      ctx.response.print "456"
      ctx.response.flush
      output.to_s.should contain("123")
      output.to_s.should contain("456")
      nil
    }
    handler.call(HTTP::Server::Context.new(HTTP::Request.new("GET", "/large"), response))
    response.close
    config.stats.stores.should eq(0)
  end

  it "checks weak and wildcard tags and uses an exact modification timestamp" do
    config = Kemal::Cache::Config.new(auto_etag: false)
    mount_cache(config) do
      get "/tag" do |env|
        env.response.headers["ETag"] = %("same")
        env.response.headers["Last-Modified"] = "Wed, 01 Jan 2025 00:00:01 GMT"
        "new"
      end
      get("/no-tag") { "present" }
    end

    get "/tag"
    get "/tag", headers: HTTP::Headers{"If-None-Match" => %(W/"same")}
    response.status_code.should eq(304)
    get "/tag", headers: HTTP::Headers{"If-Modified-Since" => "Wed, 01 Jan 2025 00:00:00 GMT"}
    response.status_code.should eq(200)
    response.body.should eq("new")
    get "/no-tag"
    get "/no-tag", headers: HTTP::Headers{"If-None-Match" => "*"}
    response.status_code.should eq(304)
  end

  it "lets the origin handle conditional POSTs and preserves cached errors" do
    config = Kemal::Cache::Config.new(cacheable_methods: ["GET", "POST"], cacheable_status_codes: nil)
    mount_cache(config) do
      post "/precondition" do |env|
        env.response.headers["ETag"] = %("same")
        if env.request.if_none_match
          env.response.status_code = 412
          "precondition failed"
        else
          "created"
        end
      end
      get "/forbidden" do |env|
        env.response.status_code = 403
        env.response.headers["ETag"] = %("same")
        "forbidden"
      end
    end

    post "/precondition"
    post "/precondition", headers: HTTP::Headers{"If-None-Match" => %("same")}
    response.status_code.should eq(412)
    get "/forbidden"
    get "/forbidden", headers: HTTP::Headers{"If-None-Match" => %("same")}
    response.status_code.should eq(403)
  end

  it "honors response freshness and bypasses cache for no-cache requests" do
    store = RecordingStore.new
    count = 0
    mount_cache(Kemal::Cache::Config.new(store: store)) do
      get "/zero-age" do |env|
        env.response.headers["Cache-Control"] = "max-age=0"
        count += 1
        count.to_s
      end
      get "/freshness" do |env|
        env.response.headers["Cache-Control"] = "max-age=10, s-maxage=3"
        env.response.headers["Age"] = "1"
        count += 1
        count.to_s
      end
    end

    get "/zero-age"
    get "/zero-age"
    response.body.should eq("2")
    store.last_key.should be_nil

    get "/freshness"
    store.last_ttl.should eq(2.seconds)
    get "/freshness", headers: HTTP::Headers{"Cache-Control" => "no-cache"}
    response.body.should eq("4")
  end

  it "does not store responses started before invalidate or clear" do
    [false, true].each do |clear|
      entered = Channel(Nil).new
      release = Channel(Nil).new
      done = Channel(HTTP::Client::Response).new
      config = Kemal::Cache::Config.new
      other_config = Kemal::Cache::Config.new(store: config.store)
      handler = Kemal::Cache::Handler.new(config)
      handler.next = CoordinatedResponseHandler.new(entered, release, "old value")
      spawn { done.send(process_request(handler, HTTP::Request.new("GET", "/test"))) }
      entered.receive
      cleared = clear ? other_config.try_clear_cache : other_config.try_invalidate("/test")
      release.send(nil)
      done.receive.body.should eq("old value")
      cleared.should be_true
      config.store.get("/test").should be_nil
    end
  end

  it "does not cache flushed bytes when the route changes headers after forwarding" do
    config = Kemal::Cache::Config.new(cache_streaming: true)
    mount_cache(config) do
      get "/private-stream" do |env|
        env.response.headers["Cache-Control"] = "public"
        env.response.flush
        env.response.headers["Cache-Control"] = "private"
        env.response.print "first"
        env.response.flush
        env.response.headers["Cache-Control"] = "public"
        "last"
      end
    end

    2.times do
      get "/private-stream"
      response.headers["Cache-Control"].should eq("private")
      response.headers["X-Kemal-Cache"].should eq("MISS")
      response.body.should eq("firstlast")
    end
  end

  it "does not store responses with cookies queued by the route" do
    mount_cache do
      get "/cookie-jar" do |env|
        env.response.cookies["example"] = "value"
        "cookie"
      end
    end

    2.times do
      get "/cookie-jar"
      response.headers["X-Kemal-Cache"].should eq("MISS")
      response.headers["Set-Cookie"].should contain("example=value")
    end
  end

  it "keeps explicitly cacheable redirects storable when the route closes the response" do
    config = Kemal::Cache::Config.new(cacheable_status_codes: [302])
    mount_cache(config) { get("/redirect") { |env| env.redirect("/elsewhere") } }

    get "/redirect"
    response.status_code.should eq(302)
    response.headers["X-Kemal-Cache"].should eq("MISS")
    get "/redirect"
    response.status_code.should eq(302)
    response.headers["X-Kemal-Cache"].should eq("HIT")
    response.headers["Location"].should eq("/elsewhere")
  end

  it "preserves explicit resource lengths on cached HEAD responses" do
    config = Kemal::Cache::Config.new(cacheable_methods: ["HEAD"])
    mount_cache(config) do
      Kemal::RouteHandler::INSTANCE.add_route("HEAD", "/head-length") do |env|
        env.response.content_length = 42
        ""
      end
    end

    head "/head-length"
    response.headers["Content-Length"].should eq("42")
    head "/head-length"
    response.headers["X-Kemal-Cache"].should eq("HIT")
    response.headers["Content-Length"].should eq("42")
  end

  it "accounts for time spent in the cache in the Age header" do
    store = RecordingStore.new
    store.prime("/aged", Kemal::Cache::CachedResponse.new(
      status_code: 200,
      headers: {"Cache-Control" => ["max-age=60"], "Age" => ["5"]},
      body: "aged",
      request_method: "GET",
      vary_request_headers: {} of String => String?,
      stored_at: Time.utc - 4.seconds,
      origin_age: 5_i64,
    ).to_json)
    mount_cache(Kemal::Cache::Config.new(store: store)) { get("/aged") { "origin" } }

    get "/aged"
    response.headers["X-Kemal-Cache"].should eq("HIT")
    response.headers["Age"].to_i.should be >= 9
  end

  it "treats payloads from the previous format as misses" do
    store = RecordingStore.new
    store.prime("/legacy", %({"status_code":200,"headers":{},"body":"legacy"}))
    mount_cache(Kemal::Cache::Config.new(store: store)) { get("/legacy") { "refreshed" } }

    get "/legacy"
    response.headers["X-Kemal-Cache"].should eq("MISS")
    response.body.should eq("refreshed")
    get "/legacy"
    response.headers["X-Kemal-Cache"].should eq("HIT")
  end

  it "uses connection close to frame streamed HTTP/1.0 responses" do
    handler = Kemal::Cache::Handler.new
    handler.next = ->(context : HTTP::Server::Context) do
      context.response.print "first"
      context.response.flush
      context.response.print "last"
    end
    server = HTTP::Server.new(handler)
    address = server.bind_tcp("127.0.0.1", 0)
    spawn { server.listen }
    TCPSocket.open(address.address, address.port) do |socket|
      socket.read_timeout = 2.seconds
      socket << "GET / HTTP/1.0\r\nHost: localhost\r\nConnection: keep-alive\r\n\r\n"
      wire = socket.gets_to_end
      wire.should contain("Connection: close\r\n")
      wire.should end_with("firstlast")
    end
  ensure
    server.try(&.close)
  end

  it "closes an HTTP/1.0 stream when a length is removed after an empty flush" do
    handler = Kemal::Cache::Handler.new
    handler.next = ->(context : HTTP::Server::Context) do
      context.response.content_length = 4
      context.response.flush
      context.response.headers.delete("Content-Length")
      context.response.print "body"
      context.response.flush
    end
    server = HTTP::Server.new(handler)
    address = server.bind_tcp("127.0.0.1", 0)
    spawn { server.listen }
    TCPSocket.open(address.address, address.port) do |socket|
      socket.read_timeout = 2.seconds
      socket << "GET / HTTP/1.0\r\nHost: localhost\r\nConnection: keep-alive\r\n\r\n"
      socket.gets_to_end.should end_with("body")
    end
  ensure
    server.try(&.close)
  end

  it "frames large buffered responses and cache hits on HTTP/1.0 keep-alive connections" do
    body = "a" * 32_768
    handler = Kemal::Cache::Handler.new
    handler.next = ->(context : HTTP::Server::Context) { context.response.print body }
    server = HTTP::Server.new(handler)
    address = server.bind_tcp("127.0.0.1", 0)
    spawn { server.listen }
    TCPSocket.open(address.address, address.port) do |socket|
      socket.read_timeout = 2.seconds
      {"MISS", "HIT"}.each do |expected|
        socket << "GET / HTTP/1.0\r\nHost: localhost\r\nConnection: keep-alive\r\n\r\n"
        headers = socket.gets("\r\n\r\n").not_nil!
        headers.should contain("Content-Length: #{body.bytesize}\r\n")
        headers.should contain("X-Kemal-Cache: #{expected}\r\n")
        socket.read_string(body.bytesize).should eq(body)
      end
    end
  ensure
    server.try(&.close)
  end

  it "lets concurrent live streams proceed even when cache misses collapse" do
    config = Kemal::Cache::Config.new(cache_streaming: true, collapse_concurrent_misses: true)
    handler = Kemal::Cache::Handler.new(config)
    entered = Channel(Nil).new(2)
    release = Channel(Nil).new
    done = Channel(HTTP::Client::Response).new(2)
    handler.next = ->(context : HTTP::Server::Context) do
      context.response.headers["Cache-Control"] = "no-cache"
      context.response.print "first"
      context.response.flush
      entered.send(nil)
      release.receive?
      context.response.print "last"
    end
    request = -> { process_request(handler, HTTP::Request.new("GET", "/events")) }
    spawn { done.send(request.call) }
    entered.receive
    spawn { done.send(request.call) }
    entered_before_release = select
    when entered.receive
      true
    when timeout(1.second)
      false
    end
    release.close
    2.times { done.receive.body.should eq("firstlast") }
    entered_before_release.should be_true
    config.stats.stores.should eq(0)
  end

  it "does not cache captured bytes that disagree with a committed Content-Length" do
    [false, true].each do |change_length|
      config = Kemal::Cache::Config.new(cache_streaming: true)
      handler = Kemal::Cache::Handler.new(config)
      handler.next = ->(context : HTTP::Server::Context) do
        context.response.content_length = 8
        context.response.print "half"
        context.response.flush
        context.response.headers["Content-Length"] = "4" if change_length
        nil
      end

      2.times do
        output = IO::Memory.new
        response = HTTP::Server::Response.new(output)
        handler.call(HTTP::Server::Context.new(HTTP::Request.new("GET", "/length"), response))
        response.close
        output.to_s.should contain("X-Kemal-Cache: MISS\r\n")
      end
      config.stats.stores.should eq(0)
    end
  end

  it "does not store a live response whose freshness expires during delivery" do
    store = RecordingStore.new
    handler = Kemal::Cache::Handler.new(Kemal::Cache::Config.new(cache_streaming: true, store: store))
    handler.next = ->(context : HTTP::Server::Context) do
      context.response.headers["Cache-Control"] = "max-age=1"
      context.response.print "first"
      context.response.flush
      sleep 1100.milliseconds
      context.response.print "last"
    end

    process_request(handler, HTTP::Request.new("GET", "/stream-expired")).body.should eq("firstlast")
    store.last_key.should be_nil
  end

  it "revalidates with an ETag supplied by upstream middleware" do
    upstream_etag = %("upstream")
    use RequestHeaderHandler.new("ETag", ->(_context : HTTP::Server::Context) { upstream_etag })
    mount_cache { get("/upstream-validator") { "body" } }

    get "/upstream-validator"
    response.headers["ETag"].should eq(%("upstream"))
    get "/upstream-validator", headers: HTTP::Headers{"If-None-Match" => %("upstream")}
    response.status_code.should eq(304)
    response.headers["X-Kemal-Cache"].should eq("HIT")

    upstream_etag = %("newer")
    get "/upstream-validator", headers: HTTP::Headers{"If-None-Match" => upstream_etag}
    response.status_code.should eq(200)
    response.headers["ETag"].should eq(%("upstream"))
    response.body.should eq("body")
  end

  it "preserves an upstream Vary declaration when replaying its representation" do
    vary = "Accept-Language"
    use RequestHeaderHandler.new("Vary", ->(_context : HTTP::Server::Context) { vary })
    mount_cache { get("/upstream-vary") { "body" } }
    headers = HTTP::Headers{"Accept-Language" => "en"}

    get "/upstream-vary", headers: headers
    response.headers["Vary"].should eq("Accept-Language")

    vary = ""
    get "/upstream-vary", headers: headers
    response.headers["X-Kemal-Cache"].should eq("HIT")
    response.headers["Vary"].should eq("Accept-Language")
  end

  it "matches Vary against the headers received before the route changes them" do
    mount_cache do
      get "/normalized" do |env|
        locale = env.request.headers["Accept-Language"]
        env.request.headers["Accept-Language"] = "en"
        env.response.headers["Vary"] = "Accept-Language"
        locale
      end
    end

    get "/normalized", headers: HTTP::Headers{"Accept-Language" => "ko"}
    get "/normalized", headers: HTTP::Headers{"Accept-Language" => "en"}
    response.body.should eq("en")
  end
end
