# frozen_string_literal: true

require_relative "rspec/version"

module SpecGuard
  module RSpec
    # The Ruby client for SpecGuard.
    #
    # Today this is a buildable skeleton: it defines the version constant and
    # reserves the SpecGuard::RSpec namespace so the linter
    # (bin/specguard-lint) and the RSpec formatter (SpecGuard::RSpecFormatter)
    # have a home in Phase 5.
    class Error < StandardError; end
  end
end
