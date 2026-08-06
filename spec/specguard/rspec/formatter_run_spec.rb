# frozen_string_literal: true

require "tmpdir"
require "open3"

# Everything the out-of-process examples need, in a namespace of its own —
# a bare `LIB_DIR = ...` inside an `RSpec.describe` block assigns at the
# *lexical* scope, which is top level, so it would define `::LIB_DIR` and
# `::Run` for the whole suite.
module FormatterRunHelpers
  extend self

  LIB_DIR = File.expand_path("../../../lib", __dir__)
  RSPEC_EXE = Gem.bin_path("rspec-core", "rspec")
  DEFAULT_SINK = "log/test_results.jsonl"

  # A passing, a failing and a pending example, nested two levels deep, and
  # carrying **zero** `@intent:` annotations — the roadmap's cold-start case,
  # and the one the payload must still describe completely.
  MIXED_SUITE = <<~RUBY
    RSpec.describe "user" do
      context "when signed in" do
        it "can order an item" do
          sleep 0.002
          expect(1 + 1).to eq(2)
        end

        it "cannot order an item that is out of stock" do
          sleep 0.002
          expect(:in_stock).to eq(:out_of_stock)
        end

        it "can cancel an order" do
          pending "cancellation is not built yet"
          sleep 0.002
          raise "not implemented"
        end
      end
    end
  RUBY

  GREEN_SUITE = <<~RUBY
    RSpec.describe "user" do
      it "can sign in" do
        expect(true).to be(true)
      end
    end
  RUBY

  Run = Struct.new(:exit_status, :stdout, :stderr, :lines, keyword_init: true) do
    def payload = JSON.parse(lines.last)
  end

  # Runs `rspec` as its own process in a throwaway project root, and reads back
  # everything an example might want to assert on before the root is removed.
  #
  # `--require` is not decoration: RSpec resolves `--format <constant>` by
  # constant lookup and only then guesses a path, and the path it guesses for
  # `SpecGuard::RSpecFormatter` is `spec_guard/r_spec_formatter`. RSpec
  # processes requires before it loads formatters, so this is also exactly the
  # `.rspec` incantation the README documents.
  #
  # @param prepare [#call] optional hook, handed the project root, returning
  #   environment overrides for the child.
  # @return [Run]
  def run_rspec(suite, prepare: nil)
    Dir.mktmpdir do |root|
      File.write(File.join(root, "sample_spec.rb"), suite)
      env = prepare ? prepare.call(root) : {}

      stdout, stderr, status = Open3.capture3(
        env, RbConfig.ruby, "-I", LIB_DIR, RSPEC_EXE,
        "--require", "specguard/rspec/formatter",
        "--format", "SpecGuard::RSpecFormatter",
        "--format", "progress",
        "sample_spec.rb",
        chdir: root
      )

      sink = File.join(root, env.fetch("SPECGUARD_OUTPUT_PATH", DEFAULT_SINK))
      lines = File.exist?(sink) ? File.readlines(sink, chomp: true) : []

      Run.new(exit_status: status.exitstatus, stdout: stdout, stderr: stderr, lines: lines)
    end
  end

  # A regular file where a directory has to go. Chosen over `chmod` on purpose:
  # these suites run as root in CI containers, and root ignores the permission
  # bits — a `chmod 0500` "unwritable path" is quietly writable again, and the
  # example passes without having tested anything.
  def blocked_sink
    lambda do |root|
      File.write(File.join(root, "blocker"), "not a directory")
      { "SPECGUARD_OUTPUT_PATH" => "blocker/test_results.jsonl" }
    end
  end
end

# The formatter in a real `rspec` process, which is the only place two of its
# promises can actually be observed:
#
#   * that it is **additive** — the human formatter still runs (criterion 1);
#   * that it **never blocks CI** — the exit code the shell sees is the suite's
#     alone, even when the sink is broken (criterion 5).
#
# In-process assertions cannot see either: a formatter's exception escapes
# `RSpec::Core::Runner.run` and takes RSpec's exit code with it, so "the process
# still exited 0" is a claim about a process. Shelling out is also how
# exit_contract_spec.rb tests the linter's exit codes, and it keeps the fixture
# suite out of `spec/fixtures/` — these suites are written into a tmpdir, so
# spec_helper's fixture-leak guard has nothing to catch.
RSpec.describe "SpecGuard::RSpecFormatter in a real rspec run" do
  include FormatterRunHelpers

  describe "a suite with a passing, a failing and a pending example, and no annotations" do
    # Once for the whole block: each example here interrogates a different part
    # of the same run, and spawning a fresh `rspec` process per assertion buys
    # nothing but seconds.
    before(:context) { @run = run_rspec(FormatterRunHelpers::MIXED_SUITE) }

    let(:run) { @run }
    let(:specs) { run.payload["specs"] }

    # Criterion 1. The reason to check for progress's marks specifically: a
    # formatter that *replaced* the human one would still leave a summary on
    # stdout, so "there was output" proves nothing.
    it "runs alongside --format progress rather than replacing it" do
      expect(run.stdout).to include(".F*")
      expect(run.stdout).to include("3 examples, 1 failure, 1 pending")
    end

    it "appends exactly one JSON object for the run" do
      expect(run.lines.length).to eq(1)
    end

    # Criterion 4.
    it "records every example in the suite, not just an annotated subset" do
      expect(specs.length).to eq(3)
    end

    # Criterion 3. The composed string is the point: `full_description` is what
    # makes a test identifiable across runs, and it only exists once the
    # describe, the context and the it are joined.
    it "names each example by its full, composed description" do
      expect(specs.map { |spec| spec["name"] }).to eq(
        [
          "user when signed in can order an item",
          "user when signed in cannot order an item that is out of stock",
          "user when signed in can cancel an order"
        ]
      )
    end

    # Criterion 2.
    it "records each example's outcome" do
      expect(specs.map { |spec| spec["outcome"] }).to eq(%w[passed failed pending])
    end

    it "records a real duration for every example, pending ones included" do
      expect(specs.map { |spec| spec["duration"] }).to all(be_a(Float).and(be > 0))
    end

    it "records where each example lives, relative to the project root" do
      expect(specs.map { |spec| spec["file_path"] }).to all(eq("sample_spec.rb"))
      expect(specs.map { |spec| spec["line_number"] }).to eq([3, 8, 13])
    end

    it "wraps them in a run envelope" do
      expect(run.payload.keys).to contain_exactly("commit_sha", "branch", "duration_seconds", "specs")
      expect(run.payload["duration_seconds"]).to be_a(Float).and be > 0
    end

    # Slice 2's job, and worth pinning as absent: a consumer that saw a null
    # `intent` here could not tell "not captured yet" from "not annotated".
    it "does not yet claim anything about annotations" do
      expect(specs.first.keys).to contain_exactly("file_path", "line_number", "name", "duration", "outcome")
    end

    it "leaves the suite's own exit status alone" do
      expect(run.exit_status).to eq(1)
    end

    it "says nothing on stderr when everything works" do
      expect(run.stderr).to be_empty
    end
  end

  describe "the run envelope" do
    it "takes the commit and branch from the environment" do
      run = run_rspec(FormatterRunHelpers::GREEN_SUITE, prepare: lambda { |_root|
        { "SPECGUARD_COMMIT_SHA" => "abc123", "SPECGUARD_BRANCH" => "feature/x" }
      })

      expect(run.payload).to include("commit_sha" => "abc123", "branch" => "feature/x")
    end

    it "honours a configured output path" do
      run = run_rspec(FormatterRunHelpers::GREEN_SUITE,
                      prepare: ->(_root) { { "SPECGUARD_OUTPUT_PATH" => "tmp/telemetry.jsonl" } })

      expect(run.lines.length).to eq(1)
    end
  end

  # Criterion 5, at the level that matters: the number the shell reads back.
  #
  # A `raise` in a formatter hook does not merely log — it escapes
  # `RSpec::Core::Runner.run`, so RSpec's exit code is never returned and the
  # process exits 1. Without the rescue, the green case below exits 1 with
  # "1 example, 0 failures" printed directly above it.
  describe "when the sink cannot be written" do
    before(:context) do
      @green = run_rspec(FormatterRunHelpers::GREEN_SUITE, prepare: blocked_sink)
      @red = run_rspec(FormatterRunHelpers::MIXED_SUITE, prepare: blocked_sink)
    end

    it "still exits 0 for a green suite" do
      expect(@green.stdout).to include("1 example, 0 failures")
      expect(@green.exit_status).to eq(0)
    end

    it "still exits 1 for a failing suite" do
      expect(@red.stdout).to include("3 examples, 1 failure, 1 pending")
      expect(@red.exit_status).to eq(1)
    end

    it "warns once on stderr, and leaves stdout to the human formatter" do
      expect(@green.stderr.scan(/SpecGuard: test telemetry failed/).length).to eq(1)
      expect(@green.stdout).not_to include("SpecGuard:")
    end

    it "writes nothing at all rather than a partial line somewhere else" do
      expect(@green.lines).to be_empty
    end
  end
end
