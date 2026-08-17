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
# block exists to catch. `json` is a default gem, so with no constraint its
# version follows the RUBY the suite happens to run on — and those two moved
# apart: Ruby 3.2.11 (what release.yml installs) ships json 2.9.1, five minors
# behind the parser the expectations were last measured against. The suite was
# green on a 4.x dev box and red on CI for that reason alone, with seven
# failures that named the payloads and not the cause.
#
# EXACT, not `~> 2.14`, and the exactness is the point. `Gemfile.lock` is
# gitignored (.gitignore) and release.yml uses `bundler-cache: true`, so CI
# resolves fresh on every run and there is no recorded version set anywhere in
# the repository. Under a floor, "which parser did we measure?" would resolve to
# "the newest 2.x that existed the moment somebody clicked Release" — 2.21.2
# today, 2.22.0 the day it ships — and the next boundary-moving minor would land
# exactly as this ticket did: at release time, on CI, red. An exact version is
# the only constraint that fixes the parser here, lock or no lock. It also makes
# a bump a one-line commit somebody writes on purpose: if this block goes red at
# that commit, the bump moved a boundary, which is precisely the signal the
# block exists to give.
#
# 2.14.0 is the measured FLOOR (kept because it is the evidence for the range,
# not because the constraint is a range): 2.13.2 is red (2 failures — the
# high-surrogate rule flipped in 2.14.0), 2.9.1 is red (7 — the depth-101 empty
# container flipped in 2.10.0), 2.14.0 through 2.21.2 are green.
#
# What this does NOT fix, deliberately, and the trade it makes:
#
#   * The two ENVIRONMENTS still differ. There is no `.ruby-version`; the dev
#     box is on 4.x and release.yml installs 3.2. This pin fixes the PARSER —
#     the only variable the block above measures — not the Ruby.
#   * The release gate no longer exercises the minimum supported environment.
#     release.yml installs Ruby 3.2 to match the gemspec's
#     `required_ruby_version >= 3.2.0`, and Ruby 3.2 ships json 2.9.1; with this
#     pin that job runs 3.2 against 2.21.2, a pairing no default consumer on the
#     declared floor has. The divergence is USER-VISIBLE, not just a suite
#     artefact: a depth-101 payload is classified `kind=parse` under 2.9.1 and
#     `kind=schema` under 2.14+, through `SpecGuard::RSpec::CLI` — live code. So
#     the red build was, narrowly, telling the truth about the shipped gem.
#     Whether to constrain `json` in the GEMSPEC, raise `required_ruby_version`,
#     or document the divergence as accepted is an architectural call and is
#     open — it was not decided by this pin, and this pin hides the signal that
#     would have raised it again. See SPGD-641 for the full write-up.
gem "json", "2.21.2"

gem "rake", "~> 13.0"
gem "rspec", "~> 3.13"
