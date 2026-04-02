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
