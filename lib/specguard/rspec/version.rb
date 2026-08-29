# frozen_string_literal: true

# Back-compat alias. The version number itself lives in `SpecGuard::VERSION`
# (lib/specguard/version.rb) since the gem became `specguard-ruby`; this
# constant is kept because released `specguard-rspec` versions exposed it and
# a consumer reaching for it should not break on the rename. It is the same
# number, not a second one — `script/bump-version.sh` edits only the source.
require_relative "../version"

module SpecGuard
  module RSpec
    VERSION = SpecGuard::VERSION
  end
end
