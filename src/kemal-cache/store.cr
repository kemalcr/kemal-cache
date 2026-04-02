module Kemal::Cache
  abstract class Store
    abstract def get(key : String) : String?
    abstract def set(key : String, value : String, ttl : Time::Span) : Nil
    abstract def delete(key : String) : Nil
    abstract def clear : Nil
  end
end
