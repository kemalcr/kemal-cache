module Kemal::Cache
  class Config
    property expires_in : Time::Span
    property store : Store
    property enabled : Bool

    def initialize(@expires_in : Time::Span = 10.minutes, @store : Store = MemoryStore.new, @enabled : Bool = true)
    end

    def storage_type : Store
      @store
    end

    def storage_type=(store : Store) : Store
      @store = store
    end
  end
end
