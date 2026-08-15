# frozen_string_literal: true

require "rubygems"

# Proves the gem loads, reserves the SpecGuard::RSpec namespace, and exposes a
# version constant that is a usable release identifier.
#
# This asserts the *contract* of VERSION, never its current literal. It used to
# read `eq("0.2.0")`, and that coupling is what made this file the one red spec
# in the repo: `script/bump-version.sh` rewrites the single `VERSION = "..."`
# line in lib/specguard/rspec/version.rb and touches nothing else, so the
# release bot's own bump (3a1b88c, 0.2.0 -> 0.2.1) left the assertion behind
# and `main` failing. A literal here means every release must remember to
# hand-edit a spec; deriving means it cannot be forgotten.
#
# Every sibling spec that touches the version already interpolates the constant
# rather than hardcoding it — schema_packaging_spec.rb, transport_spec.rb,
# formatter_loading_spec.rb, cli_spec.rb. This file was the last holdout.
# Keep it that way: a version bump must stay a one-file change.
RSpec.describe SpecGuard::RSpec do
  describe "VERSION" do
    subject(:version) { SpecGuard::RSpec::VERSION }

    # Deliberately stronger than `be_a(String)`, which would pass for "",
    # "banana", or "0.2" and leave this guard unable to fail. The shape asserted
    # is the one the release path actually requires: RubyGems publishes it as
    # the gem version and bump-version.sh splits it on "." to compute the next
    # patch and the vX.Y.Z tag, so anything that is not MAJOR.MINOR.PATCH breaks
    # the release rather than the suite.
    it "is a well-formed semver string" do
      expect(version).to be_a(String)
      expect(version).not_to be_empty
      expect(version).to match(/\A\d+\.\d+\.\d+(?:-[0-9A-Za-z.]+)?\z/)
    end

    it "is frozen, so no caller can mutate the value the gemspec published" do
      expect(version).to be_frozen
    end

    # The constant is the single source of truth: the gemspec reads it
    # (specguard-rspec.gemspec:7) instead of carrying its own literal. This is
    # the cheap, in-process half of that check — schema_packaging_spec.rb
    # asserts the same equality against a *built* gem, but only after shelling
    # out to `gem build`. Reading the gemspec directly fails fast, and fails
    # loudly if anyone ever hardcodes a version into it.
    it "is the version the gemspec publishes, not a literal copied into it" do
      gemspec_path = File.expand_path("../specguard-rspec.gemspec", __dir__)
      gemspec = Gem::Specification.load(gemspec_path)

      expect(gemspec).not_to be_nil, "#{gemspec_path} failed to load"
      expect(gemspec.version.to_s).to eq(version)
    end
  end
end
