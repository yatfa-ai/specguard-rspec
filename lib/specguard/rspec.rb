# frozen_string_literal: true

require_relative "rspec/version"

module SpecGuard
  module RSpec
    # The Ruby client for SpecGuard.
    #
    # The linter is complete end to end: it finds `@intent:` annotations in
    # spec files, captures each payload string-aware, normalizes PROTOCOL.md
    # §1's permissive syntax into strict JSON, validates the result against the
    # vendored OpenTestIntent schema, and reports violations in the reference
    # tool's own grammar under the 0/1/2 exit contract (see {CLI}).
    #
    # The RSpec formatter (`SpecGuard::RSpecFormatter`) is the other half of
    # the client, and it is deliberately **not** required from here: `rspec` is
    # a development dependency of this gem, not a runtime one, and
    # `bin/specguard-lint` loads this file on machines that may have no RSpec
    # at all. Requiring `rspec/core` from this chain would turn a missing test
    # framework into a broken linter. Load it by its own path when you want it
    # — `require "specguard/rspec/formatter"` — and see that file for the
    # opt-in wiring.
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
    # {Schema.load} reads it, and treats every way that can fail as exit 2 —
    # if a packaging accident leaves it out of the gem, the linter must say so
    # rather than blame someone's annotations.
    SCHEMA_PATH = File.expand_path("rspec/schemas/open-test-intent.v1.json", __dir__).freeze
  end
end

require_relative "rspec/finding"
require_relative "rspec/annotation_scanner"
require_relative "rspec/payload_normalizer"
require_relative "rspec/scanner"
require_relative "rspec/file_selector"
require_relative "rspec/violation_renderer"
require_relative "rspec/schema"
require_relative "rspec/linter"
require_relative "rspec/cli"
