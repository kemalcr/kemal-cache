require "spec"
require "spec-kemal"
require "../src/kemal-cache"

Spec.before_each do
  Kemal.config.env = "test"
  Kemal.config.always_rescue = false
end

Spec.after_each do
  Kemal.config.clear
end

class RequestState
  property calls : Int32

  def initialize
    @calls = 0
  end
end

class RequestHeaderHandler < Kemal::Handler
  def initialize(@name : String, @value : Proc(HTTP::Server::Context, String))
  end

  def call(context : HTTP::Server::Context)
    context.response.headers[@name] = @value.call(context)
    call_next(context)
  end
end

class CoordinatedResponseHandler < Kemal::Handler
  getter calls : Int32

  def initialize(@entered : Channel(Nil), @release : Channel(Nil), @body : String)
    @calls = 0
  end

  def call(context : HTTP::Server::Context)
    @calls += 1
    @entered.send(nil)
    @release.receive
    context.response.print @body
  end
end

class RecordingStore < Kemal::Cache::Store
  getter last_key : String?
  getter last_value : String?
  getter last_ttl : Time::Span?

  def initialize
    @entries = {} of String => String
  end

  def get(key : String) : String?
    @entries[key]?
  end

  def set(key : String, value : String, ttl : Time::Span) : Nil
    @last_key = key
    @last_value = value
    @last_ttl = ttl
    @entries[key] = value
  end

  def prime(key : String, value : String) : Nil
    @entries[key] = value
  end

  def delete(key : String) : Nil
    @entries.delete(key)
  end

  def clear : Nil
    @entries.clear
  end
end

class FailingStore < Kemal::Cache::Store
  property fail_get = false
  property fail_set = false
  property fail_delete = false
  property fail_clear = false

  def initialize
    @entries = {} of String => String
  end

  def get(key : String) : String?
    raise "store get failure" if @fail_get

    @entries[key]?
  end

  def set(key : String, value : String, ttl : Time::Span) : Nil
    raise "store set failure" if @fail_set

    @entries[key] = value
  end

  def prime(key : String, value : String) : Nil
    @entries[key] = value
  end

  def delete(key : String) : Nil
    raise "store delete failure" if @fail_delete

    @entries.delete(key)
  end

  def clear : Nil
    raise "store clear failure" if @fail_clear

    @entries.clear
  end
end

def mount_cache(config : Kemal::Cache::Config = Kemal::Cache::Config.new, &)
  use Kemal::Cache::Handler.new(config)
  yield
  Kemal.config.setup
end

def process_request(handler : HTTP::Handler, request : HTTP::Request) : HTTP::Client::Response
  io = IO::Memory.new
  response = HTTP::Server::Response.new(io)
  context = HTTP::Server::Context.new(request, response)
  handler.call(context)
  response.close
  io.rewind
  HTTP::Client::Response.from_io(io, decompress: false)
end
