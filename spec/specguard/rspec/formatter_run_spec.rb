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

  # Every shape slice 2 has to classify, in one file:
  #
  #   line  3  preceding-comment annotation      -> annotated
  #   line  7  no annotation at all              -> unannotated
  #   line 11  same-line trailing annotation     -> annotated
  #   line 16  unterminated literal (malformed)  -> unannotated
  #   line 21  parses, but `entiity` is not a schema property -> unannotated
  #   line 27  annotated, nested inside a context -> annotated
  #
  # The nested one is not decoration: `metadata[:line_number]` is the `it` line
  # regardless of how deeply the example is nested, and an implementation that
  # reached for the describe's line instead would get every one of these wrong
  # while still producing a plausible-looking payload.
  ANNOTATED_SUITE = <<~RUBY
    RSpec.describe "user" do
      # @intent: { entity: "Order", action: "checkout", behavior: "returns 402 payment required on expired card", layer: "request" }
      it "can order an item" do
        expect(1 + 1).to eq(2)
      end

      it "has no annotation" do
        expect(1 + 1).to eq(2)
      end

      it "surfaces the decline reason" do # @intent: {entity:"Order",action:"refund",behavior:"restores stock levels when a paid order is refunded",layer:"unit"}
        expect(1 + 1).to eq(2)
      end

      # @intent: { entity: "Order", action: "total",
      it "has a malformed annotation" do
        expect(1 + 1).to eq(2)
      end

      # @intent: { entiity: "Order", action: "total", behavior: "sums line item prices after the discount", layer: "unit" }
      it "has a schema-invalid annotation" do
        expect(1 + 1).to eq(2)
      end

      context "when signed in" do
        # @intent: { entity: 'Order', action: 'cancel', behavior: 'releases the reserved stock on cancellation', layer: 'unit' }
        it "can cancel an order" do
          expect(1 + 1).to eq(2)
        end
      end
    end
  RUBY

  # The shape that separates "one line of lookback" from "one line of lookback,
  # comment form only". Line 4 carries a trailing annotation *and* an example;
  # line 5 carries a different example and no annotation at all. `it { ... }`
  # one-liners are idiomatic RSpec, so nothing here is contrived — a lookback
  # that ignored the form would report both as annotated, with the same intent,
  # and inflate the platform's annotated ratio with a purpose nobody declared.
  ONE_LINER_SUITE = <<~RUBY
    RSpec.describe "Order" do
      subject { 1 }

      it { is_expected.to eq(1) } # @intent: { entity: "Order", action: "checkout", behavior: "returns 402 payment required on expired card", layer: "request" }
      it { is_expected.to be_positive }
    end
  RUBY

  # Makes the annotation lookup's one external dependency blow up, from inside
  # the child process, without touching lib/. Stands in for the family the
  # lookup cannot control: an unreadable spec file, a spec file that is not
  # valid UTF-8, a vendored schema that will not compile.
  SABOTAGE = <<~RUBY
    require "specguard/rspec"
    module SpecGuard::RSpec::Scanner
      def self.scan_text(_text, file:) = raise(IOError, "sabotaged scanner")
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
  # @param sabotage [Boolean] load {SABOTAGE} into the child before the
  #   formatter runs, so the annotation lookup's scanner raises.
  # @return [Run]
  def run_rspec(suite, prepare: nil, sabotage: false)
    Dir.mktmpdir do |root|
      File.write(File.join(root, "sample_spec.rb"), suite)
      env = prepare ? prepare.call(root) : {}

      requires = ["--require", "specguard/rspec/formatter"]
      if sabotage
        File.write(File.join(root, "sabotage.rb"), SABOTAGE)
        requires += ["--require", "./sabotage.rb"]
      end

      stdout, stderr, status = Open3.capture3(
        env, RbConfig.ruby, "-I", LIB_DIR, RSPEC_EXE,
        *requires,
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

# `Ingest::Payload`'s per-spec rules, restated.
#
# The platform lives in another repository and this gem must not depend on it,
# so the contract is transcribed rather than imported — with the file:line it
# was transcribed from on every rule, which is the only thing that makes the
# copy auditable when the original moves.
#
# The transcription is verified: run against what this formatter writes, the
# real `app/services/ingest/payload.rb` — eval'd verbatim with only `present?`
# and `presence` shimmed — returns `valid?=true` with an empty error list, and
# derives `total_specs_count=6 annotated_specs_count=3`. Against slice 1's
# output, the same file returns one error *per spec*
# ("status must be one of annotated, unannotated") and the controller
# (`api/v1/ingests_controller.rb:10`) renders 400.
#
# Note what the second probe also showed: without `status`, the platform's
# `annotated_specs` — which *rejects* `"unannotated"` rather than selecting
# `"annotated"` (`payload.rb:33`) — counted all six as annotated. So the field
# is not merely required; it is the one that stops the headline metric being
# 100% for a suite with no annotations in it at all.
module IngestContract
  STATUSES = %w[annotated unannotated].freeze # payload.rb:17

  module_function

  # @return [Array<String>] one message per violated rule; empty means the
  #   platform would accept this spec entry.
  def errors_for(spec, index)
    label = "specs[#{index}]"
    errors = []

    # payload.rb:101-106
    unless spec["file_path"].is_a?(String) && !spec["file_path"].to_s.strip.empty?
      errors << "#{label}: file_path is required and must be a non-empty string"
    end

    # payload.rb:108-113
    unless spec["line_number"].is_a?(Integer) && spec["line_number"].positive?
      errors << "#{label}: line_number is required and must be a positive integer"
    end

    # payload.rb:115-119
    errors << "#{label}: status must be one of #{STATUSES.join(', ')}" unless STATUSES.include?(spec["status"])

    errors + intent_errors(spec, label)
  end

  # payload.rb:124-141
  def intent_errors(spec, label)
    intent = spec["intent"]

    case spec["status"]
    when "annotated"
      return ["#{label}: intent is required when status is \"annotated\""] if intent.nil?
      return ["#{label}: intent must be a JSON object"] unless intent.is_a?(Hash)

      # payload.rb:134 — the platform re-validates every annotated intent
      # against the same OpenTestIntent schema this gem vendors.
      schema.violations(intent).map { |reason| "#{label}: intent is invalid — #{reason}" }
    when "unannotated"
      intent.nil? ? [] : ["#{label}: intent must be null when status is \"unannotated\""]
    else
      []
    end
  end

  # Memoized because {#errors_for} is called once per spec entry, and
  # `Schema.load` reads, parses and compiles the vendored document every time.
  # Paying that per entry would make this fixture's own cost O(specs) — the
  # shape the code it is checking exists to avoid.
  def schema
    @schema ||= SpecGuard::RSpec::Schema.load
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

    # A suite with no annotations is the cold-start case, and it must still say
    # so *positively*. "No annotations here" and "this producer does not report
    # annotations" are different facts, and only one of them is true.
    it "reports every example as unannotated, with a null intent" do
      expect(specs.map { |spec| spec["status"] }).to all(eq("unannotated"))
      expect(specs.map { |spec| spec["intent"] }).to all(be_nil)
    end

    it "carries exactly the fields the platform's spec entry is made of" do
      expect(specs.first.keys)
        .to contain_exactly("file_path", "line_number", "name", "duration", "outcome", "status", "intent")
    end

    it "leaves the suite's own exit status alone" do
      expect(run.exit_status).to eq(1)
    end

    it "says nothing on stderr when everything works" do
      expect(run.stderr).to be_empty
    end
  end

  # Criterion 2: all four placements, resolved in one real run — plus the two
  # downgrades, because an implementation that got those wrong would still get
  # these four right.
  describe "a suite exercising every annotation shape" do
    before(:context) { @run = run_rspec(FormatterRunHelpers::ANNOTATED_SUITE) }

    let(:run) { @run }
    let(:specs) { run.payload["specs"] }
    let(:by_name) { specs.to_h { |spec| [spec["name"], spec] } }

    def status_of(name) = by_name.fetch("user #{name}")["status"]

    it "runs all six examples" do
      expect(run.stdout).to include("6 examples, 0 failures")
      expect(specs.length).to eq(6)
    end

    it "annotates an example from the comment line above it" do
      expect(status_of("can order an item")).to eq("annotated")
      expect(by_name.fetch("user can order an item")["intent"])
        .to include("entity" => "Order", "action" => "checkout", "layer" => "request")
    end

    it "annotates an example from a trailing annotation on its own line" do
      expect(status_of("surfaces the decline reason")).to eq("annotated")
      expect(by_name.fetch("user surfaces the decline reason")["intent"]).to include("action" => "refund")
    end

    # `metadata[:line_number]` is the `it` line however deeply the example is
    # nested, so a context adds no offset to reason about.
    it "annotates an example nested inside a context" do
      expect(by_name.fetch("user when signed in can cancel an order"))
        .to include("status" => "annotated", "line_number" => 27)
    end

    it "reports an example with no annotation as unannotated" do
      expect(status_of("has no annotation")).to eq("unannotated")
      expect(by_name.fetch("user has no annotation")["intent"]).to be_nil
    end

    # Criterion 3, end to end. Both of these are annotations the *linter* exits
    # 1 over. Here they cost their own example's metadata and nothing else.
    it "downgrades a malformed annotation rather than shipping or failing on it" do
      expect(by_name.fetch("user has a malformed annotation"))
        .to include("status" => "unannotated", "intent" => nil, "outcome" => "passed")
    end

    it "downgrades a schema-invalid annotation the same way" do
      expect(by_name.fetch("user has a schema-invalid annotation"))
        .to include("status" => "unannotated", "intent" => nil, "outcome" => "passed")
    end

    it "still ships the name, duration and outcome of a downgraded example" do
      downgraded = by_name.fetch("user has a malformed annotation")

      expect(downgraded["duration"]).to be_a(Float)
      expect(downgraded["line_number"]).to eq(16)
    end

    it "keeps quiet about all of it" do
      expect(run.stderr).to be_empty
      expect(run.exit_status).to eq(0)
    end

    # Criterion 4 — the criterion that proves slice 3 is unblocked. Asserted
    # per entry rather than as a single count, so a failure names the spec and
    # the rule instead of moving a total from 6 to 5.
    describe "the platform's ingest contract" do
      it "produces a spec entry the platform accepts, for every example" do
        violations = specs.each_with_index.flat_map { |spec, index| IngestContract.errors_for(spec, index) }

        expect(violations).to be_empty
      end

      it "gives every spec a status the platform's enum admits" do
        expect(specs.map { |spec| spec["status"] } - IngestContract::STATUSES).to be_empty
      end

      it "gives every annotated spec an intent object, and every unannotated one none" do
        annotated, unannotated = specs.partition { |spec| spec["status"] == "annotated" }

        expect(annotated.map { |spec| spec["intent"] }).to all(be_a(Hash))
        expect(annotated.length).to eq(3)
        expect(unannotated.map { |spec| spec["intent"] }).to all(be_nil)
      end

      # The counts the platform derives from this payload (`payload.rb:38-46`),
      # and the reason `status` is load-bearing rather than informational: this
      # ratio is the headline dashboard metric.
      it "supports the annotated ratio the platform derives, rather than a vacuous 100%" do
        annotated = specs.count { |spec| spec["status"] == "annotated" }

        expect(annotated).to eq(3)
        expect(annotated).to be < specs.length
      end
    end
  end

  # A trailing annotation belongs to the example it was written on, and to no
  # other. The lookback window is one line wide either way; what this run pins
  # is that the *form* decides who may look through it.
  describe "a suite of one-liner examples with a trailing annotation" do
    before(:context) { @run = run_rspec(FormatterRunHelpers::ONE_LINER_SUITE) }

    let(:run) { @run }
    let(:specs) { run.payload["specs"] }
    let(:by_name) { specs.to_h { |spec| [spec["name"], spec] } }

    it "runs both examples" do
      expect(run.stdout).to include("2 examples, 0 failures")
      expect(specs.length).to eq(2)
    end

    it "annotates the example the annotation was written on" do
      expect(by_name.fetch("Order is expected to eq 1"))
        .to include("status" => "annotated", "line_number" => 4)
    end

    # The defect this fixture exists for: line 5 declared nothing, and a payload
    # that says otherwise is not a gap in the data, it is wrong data.
    it "does not lend that annotation to the example on the next line" do
      expect(by_name.fetch("Order is expected to be positive"))
        .to include("status" => "unannotated", "intent" => nil, "line_number" => 5)
    end

    # Stated as the number the dashboard reads, because that is where the
    # inflation would show up: 2 of 2 annotated for a file with one annotation.
    it "reports one annotated example, not two" do
      expect(specs.count { |spec| spec["status"] == "annotated" }).to eq(1)
    end

    it "still produces a spec entry the platform accepts, for both examples" do
      violations = specs.each_with_index.flat_map { |spec, index| IngestContract.errors_for(spec, index) }

      expect(violations).to be_empty
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

  # Criterion 6, at the process level, for slice 2's own failure modes.
  #
  # The lookup reads spec files off disk and compiles a JSON Schema, so it can
  # fail in ways slice 1's capture layer could not: a spec file that is not
  # readable, one that is not valid UTF-8, a vendored schema that will not load.
  # The suite under test here is otherwise entirely ordinary — what is broken is
  # SpecGuard, and the numbers below are the ones the shell reads back.
  describe "when the annotation scanner blows up" do
    before(:context) do
      @green = run_rspec(FormatterRunHelpers::GREEN_SUITE, sabotage: true)
      @red = run_rspec(FormatterRunHelpers::MIXED_SUITE, sabotage: true)
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
      expect(@red.stderr.scan(/SpecGuard: test telemetry failed/).length).to eq(1)
      expect(@red.stdout).not_to include("SpecGuard:")
    end

    # The distinction the inner rescue exists for. A failure this deep must cost
    # the run its *annotations*, not its examples — a payload of zero specs
    # would be indistinguishable from a suite nobody ran.
    it "still records every example, as unannotated" do
      expect(@red.payload["specs"].length).to eq(3)
      expect(@red.payload["specs"].map { |spec| spec["status"] }).to all(eq("unannotated"))
    end

    it "still produces a payload the platform would accept" do
      violations = @red.payload["specs"].each_with_index.flat_map do |spec, index|
        IngestContract.errors_for(spec, index)
      end

      expect(violations).to be_empty
    end
  end
end
