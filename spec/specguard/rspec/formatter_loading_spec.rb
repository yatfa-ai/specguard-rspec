# frozen_string_literal: true

require "open3"

# The load-time separation between the gem's two halves.
#
# `specguard-rspec.gemspec` declares exactly one runtime dependency —
# `json_schemer`. `rspec` is a **development** gem here, listed only in the
# Gemfile. `bin/specguard-lint` loads `specguard/rspec`, so anyone who installed
# this gem purely to lint annotations must be able to load that on a machine
# with no RSpec at all: their CI lint step may well be a `gem install` in a
# container that never runs a test.
#
# That makes "does `require "specguard/rspec"` pull in `rspec/core`?" a real
# packaging contract rather than a stylistic preference, and one that a single
# stray `require_relative "rspec/formatter"` at the bottom of lib/specguard/rspec.rb
# would break invisibly — invisibly, because in *this* repo RSpec is always
# present, so every other spec would keep passing.
#
# Hence a subprocess: it is the only way to observe a load path that has not
# already been contaminated by the suite currently running.
RSpec.describe "the gem's load boundary" do
  # A method rather than a constant: a bare `LIB = ...` inside an
  # `RSpec.describe` block assigns at the lexical scope, which is top level.
  def lib_dir
    File.expand_path("../../../lib", __dir__)
  end

  # @return [[String, String, Integer]] stdout, stderr and the exit status of a
  #   fresh interpreter that has been handed nothing but our lib/ directory.
  def load_in_fresh_ruby(source)
    stdout, stderr, status = Open3.capture3(RbConfig.ruby, "-I", lib_dir, "-e", source)
    [stdout, stderr, status.exitstatus]
  end

  # Criterion 7.
  describe "require \"specguard/rspec\" — the linter's entry point" do
    subject(:result) do
      load_in_fresh_ruby(<<~RUBY)
        require "specguard/rspec"
        puts(defined?(::RSpec::Core) ? "rspec-core DEFINED" : "rspec-core absent")
        puts "loaded_features=\#{$LOADED_FEATURES.grep(%r{/rspec/core}).length}"
        puts "linter=\#{SpecGuard::RSpec::CLI.name}"
      RUBY
    end

    let(:stdout) { result[0] }

    it "loads without error" do
      expect(result[2]).to eq(0), "stderr was: #{result[1]}"
    end

    it "does not define RSpec::Core" do
      expect(stdout).to include("rspec-core absent")
    end

    # The stronger form: not merely "the constant is missing" but "not one file
    # of rspec-core was read", which also catches a partial require.
    it "does not load a single file of rspec-core" do
      expect(stdout).to include("loaded_features=0")
    end

    it "still gives the linter everything it needs" do
      expect(stdout).to include("linter=SpecGuard::RSpec::CLI")
    end
  end

  describe "require \"specguard/rspec/formatter\" — the opt-in half" do
    subject(:result) do
      load_in_fresh_ruby(<<~RUBY)
        require "specguard/rspec/formatter"
        puts "formatter=\#{SpecGuard::RSpecFormatter.name}"
        puts "superclass=\#{SpecGuard::RSpecFormatter.superclass.name}"
        puts "configurable=\#{SpecGuard::RSpec.configuration.output_path}"
      RUBY
    end

    let(:stdout) { result[0] }

    # Standalone: it must not assume the linter half was required first, or the
    # documented one-line `.rspec` opt-in would only work by accident.
    it "loads on its own, without specguard/rspec having been required" do
      expect(result[2]).to eq(0), "stderr was: #{result[1]}"
      expect(stdout).to include("formatter=SpecGuard::RSpecFormatter")
    end

    # The constant-resolution trap, observed from outside: inside `module
    # SpecGuard`, an unqualified `RSpec::Core` resolves to `SpecGuard::RSpec::Core`.
    # If the `::` qualification were ever dropped, this require would die with
    # `NameError: uninitialized constant SpecGuard::RSpec::Core`.
    it "subclasses the real RSpec's BaseFormatter" do
      expect(stdout).to include("superclass=RSpec::Core::Formatters::BaseFormatter")
    end

    it "brings the configuration with it" do
      expect(stdout).to include("configurable=log/test_results.jsonl")
    end
  end
end
