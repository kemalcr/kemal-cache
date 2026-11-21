require "base64"

module Kemal::Cache
  struct CachedResponse
    include JSON::Serializable

    getter status_code : Int32
    getter headers : Hash(String, Array(String))
    getter request_method : String?
    getter vary_request_headers : Hash(String, String?)?
    getter stored_at : Time?
    getter origin_age : Int64?

    @[JSON::Field(key: "body")]
    @text_body : String
    @body_base64 : String?

    def initialize(
      @status_code : Int32,
      @headers : Hash(String, Array(String)),
      body : String,
      @request_method : String? = nil,
      @vary_request_headers : Hash(String, String?)? = nil,
      @stored_at : Time? = nil,
      @origin_age : Int64? = nil,
    )
      if body.valid_encoding?
        @text_body = body
      else
        @text_body = ""
        @body_base64 = Base64.strict_encode(body)
      end
    end

    def body : String
      if encoded = @body_base64
        Base64.decode_string(encoded)
      else
        @text_body
      end
    end
  end
end
