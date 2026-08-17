# frozen_string_literal: true

source "https://rubygems.org"

# Specify your gem's dependencies in specguard-rspec.gemspec
gemspec

gem "irb"

# NOT a runtime dependency — deliberately absent from the gemspec, so a user's
# `json` stays whatever their Ruby ships. This pin exists for the SUITE.
#
# `validator_backend_spec.rb`'s "JSON acceptance set" block pins `JSON.parse`'s
# boundaries EXACTLY (the surrogate rule, the nesting off-by-one) rather than
# bracketing them, because a `json` release that moves one is the change that
# block exists to catch. `json` is a default gem, so without a pin its version
# follows the RUBY the suite happens to run on — and those two moved apart:
# Ruby 3.2.11 (what release.yml installs) ships json 2.9.1, five minors behind
# the parser the expectations were last measured against. The suite was green
# on a 4.x dev box and red on CI for that reason alone, with seven failures
# that named the payloads and not the cause.
#
# 2.14.0 is the measured floor, not a guess: 2.13.2 is red (2 failures — the
# high-surrogate rule flipped in 2.14.0), 2.9.1 is red (7 — the depth-101 empty
# container flipped in 2.10.0), 2.14.0 through 2.21.2 are green. Capped at the
# major because a 3.0 may move any of it.
gem "json", "~> 2.14"

gem "rake", "~> 13.0"
gem "rspec", "~> 3.13"
