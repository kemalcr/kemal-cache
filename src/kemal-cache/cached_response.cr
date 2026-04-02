module Kemal::Cache
  struct CachedResponse
    include JSON::Serializable

    getter status_code : Int32
    getter headers : Hash(String, Array(String))
    getter body : String

    def initialize(@status_code : Int32, @headers : Hash(String, Array(String)), @body : String)
    end
  end
end
