# frozen_string_literal: true

require_relative "rspec/version"

module SpecGuard
  module RSpec
    # The Ruby client for SpecGuard.
    #
    # This slice ships the linter's *input pipeline*: it finds `@intent:`
    # annotations in spec files, captures each payload string-aware, normalizes
    # PROTOCOL.md §1's permissive syntax into strict JSON, and parses it into a
    # Hash. It stops there deliberately — loading the vendored schema, applying
    # it, and the `0`/`1`/`2` exit contract are the next slice, and
    # `bin/specguard-lint` still exits 0 in every case until then.
    #
    # The RSpec formatter (`SpecGuard::RSpecFormatter`) is a separate piece of
    # work and has no home here yet.
    class Error < StandardError; end

    # A source line could not be scanned (unterminated string or object
    # literal). Internal to the scanner: it is caught and turned into a
    # {Finding}'s `problem` rather than reaching a caller.
    class ScanError < Error; end

    # The tool was invoked in a way that cannot work — `--changed` outside a git
    # repository, say. Distinct from "the annotations are bad": the exit-code
    # contract makes this a 2, and it is typed here so the CLI can map it
    # without re-deriving the distinction from an error message.
    class UsageError < Error; end

    # The vendored canonical OpenTestIntent schema, copied byte-for-byte from
    # open-test-intent so this gem has **no cross-repo runtime dependency**.
    # It ships packaged (it lives under `lib/`, which the gemspec includes);
    # the spec fixtures deliberately do not, so nothing here may be
    # load-bearing at runtime.
    #
    # Nothing reads it yet — applying it is the next slice. It is vendored now
    # so that slice is purely additive.
    SCHEMA_PATH = File.expand_path("rspec/schemas/open-test-intent.v1.json", __dir__).freeze
  end
end

require_relative "rspec/finding"
require_relative "rspec/annotation_scanner"
require_relative "rspec/payload_normalizer"
require_relative "rspec/scanner"
require_relative "rspec/file_selector"
require_relative "rspec/cli"
