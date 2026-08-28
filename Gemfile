# frozen_string_literal: true

source "https://rubygems.org"

# Specify your gem's dependencies in specguard-rspec.gemspec
gemspec

# Development-only: spec/support/validator_stub.rb uses json_schemer to give
# ad-hoc spec fixtures REAL verdicts offline. Since SPGD-867 the gem's lib/
# never touches json_schemer — validation is the binary's job — and the
# gemspec deliberately declares no such runtime dependency.
gem "json_schemer", "~> 2.5"

gem "irb"
gem "rake", "~> 13.0"
gem "rspec", "~> 3.13"
