# frozen_string_literal: true

require "tmpdir"
require "open3"
require "fileutils"

require_relative "../../support/stub_ingest_endpoint"

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

  # A table-driven loop: the `it` is written once, on line 4, so all three
  # examples report the same `metadata[:line_number]`. Nothing here is
  # contrived — this is how anyone writes a parameterised case table, and under
  # a `(file_path, line_number)` key all three collapse onto one row.
  LOOP_SUITE = <<~RUBY
    RSpec.describe "Order" do
      [["visa", 200], ["expired", 402], ["stolen", 403]].each do |card, status|
        it "returns \#{status} for a \#{card} card" do
          expect(status).to be_positive
        end
      end
    end
  RUBY

  # A shared example group defined in `spec/support/shared.rb` and run from two
  # different spec files. Every one of the four examples is *defined* at the
  # same two coordinates, and `spec/support/shared.rb` is not a `*_spec.rb` at
  # all — so under the old key the two files that actually ran the tests appear
  # nowhere in the payload.
  SHARED_EXAMPLE_FILES = {
    "spec/support/shared.rb" => <<~RUBY,
      RSpec.shared_examples "a persisted record" do
        it "has an identifier" do
          expect(1).to be_positive
        end

        it "survives a reload" do
          expect(true).to be(true)
        end
      end
    RUBY
    "spec/orders_spec.rb" => <<~RUBY,
      require_relative "support/shared"

      RSpec.describe "Order" do
        it_behaves_like "a persisted record"
      end
    RUBY
    "spec/users_spec.rb" => <<~RUBY
      require_relative "support/shared"

      RSpec.describe "User" do
        it_behaves_like "a persisted record"
      end
    RUBY
  }.freeze

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

  # Unset in every child unless an example asks for them. The formatter's
  # configuration seeds from the *real* ENV, so a developer or a CI job that
  # exported `SPECGUARD_API_KEY` for its own reasons would otherwise turn every
  # run below into an HTTP delivery — and each of these examples asserts on a
  # local file that would then never be written. `nil` deletes the variable in
  # the child (`Process.spawn`'s env contract).
  HERMETIC_ENV = {
    "SPECGUARD_API_KEY" => nil,
    "SPECGUARD_ENDPOINT" => nil,
    "SPECGUARD_TIMEOUT" => nil
  }.freeze

  # Runs `rspec` as its own process in a throwaway project root, and reads back
  # everything an example might want to assert on before the root is removed.
  #
  # `--require` is not decoration: RSpec resolves `--format <constant>` by
  # constant lookup and only then guesses a path, and the path it guesses for
  # `SpecGuard::RSpecFormatter` is `spec_guard/r_spec_formatter`. RSpec
  # processes requires before it loads formatters, so this is also exactly the
  # `.rspec` incantation the README documents.
  #
  # @param suite [String, nil] the single-file case, written to `sample_spec.rb`.
  # @param files [Hash{String=>String}] additional files, by root-relative path.
  #   Intermediate directories are created. Every key matching `*_spec.rb` is
  #   passed to `rspec` as a target; anything else is a support file, reachable
  #   from a spec by `require_relative`. This is what lets a shared example group
  #   be exercised the only way it can be — defined in one file, run from two.
  # @param prepare [#call] optional hook, handed the project root, returning
  #   environment overrides for the child.
  # @param sabotage [Boolean] load {SABOTAGE} into the child before the
  #   formatter runs, so the annotation lookup's scanner raises.
  # @return [Run]
  def run_rspec(suite = nil, files: {}, prepare: nil, sabotage: false)
    Dir.mktmpdir do |root|
      sources = suite ? { "sample_spec.rb" => suite }.merge(files) : files
      sources.each do |path, contents|
        full_path = File.join(root, path)
        FileUtils.mkdir_p(File.dirname(full_path))
        File.write(full_path, contents)
      end
      targets = sources.keys.grep(/_spec\.rb\z/)
      env = HERMETIC_ENV.merge(prepare ? prepare.call(root) : {})

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
        *targets,
        chdir: root
      )

      sink = File.join(root, env.fetch("SPECGUARD_OUTPUT_PATH", DEFAULT_SINK) || DEFAULT_SINK)
      lines = File.exist?(sink) ? File.readlines(sink, chomp: true) : []

      Run.new(exit_status: status.exitstatus, stdout: stdout, stderr: stderr, lines: lines)
    end
  end

  # Everything a child needs to POST to the stub. `commit_sha` is supplied
  # because the throwaway project root is not a git checkout — which is what
  # makes omitting it a *test case* rather than an accident (see "when the
  # commit cannot be determined").
  def transport_env(server, **overrides)
    {
      "SPECGUARD_ENDPOINT" => server.endpoint,
      "SPECGUARD_API_KEY" => "sgk_abc123",
      "SPECGUARD_COMMIT_SHA" => "0d4a1f2c9b8e7d6a5f4c3b2a1908f7e6d5c4b3a2",
      "SPECGUARD_BRANCH" => "main",
      "SPECGUARD_TIMEOUT" => "5"
    }.merge(overrides.transform_keys(&:to_s))
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
      expect(run.payload.keys)
        .to contain_exactly("commit_sha", "branch", "ci_run_id", "shard_id", "duration_seconds", "specs")
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
        .to contain_exactly("id", "spec_file_path", "file_path", "line_number", "name", "duration",
                            "outcome", "status", "intent")
    end

    # Criterion 3, on the ordinary suite: no two rows share an identity even
    # when nothing about the suite is unusual.
    it "gives every example an id of its own" do
      expect(specs.map { |spec| spec["id"] }.uniq.length).to eq(specs.length)
    end

    # The ordinary case: nothing is shared, so the file that ran the example and
    # the file that defined it are the same file.
    it "reports the owning spec file as the file the examples are written in" do
      expect(specs.map { |spec| spec["spec_file_path"] }).to all(eq("sample_spec.rb"))
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

  # The two shapes that make `(file_path, line_number)` the wrong key, run for
  # real. A double cannot prove either of these: it is told what `id` to answer,
  # so it would agree with any implementation. Only RSpec deciding for itself
  # says whether the identity actually separates these examples.
  describe "a table-driven loop, where one `it` produces several examples" do
    before(:context) { @run = run_rspec(FormatterRunHelpers::LOOP_SUITE) }

    let(:run) { @run }
    let(:specs) { run.payload["specs"] }

    it "runs all three examples" do
      expect(run.stdout).to include("3 examples, 0 failures")
      expect(specs.length).to eq(3)
    end

    # The defect, stated as the measurement. All three are written on line 3 —
    # that is what the loop *is* — so the coordinate has one distinct value for
    # three examples.
    it "reports one shared definition coordinate for all three" do
      expect(specs.map { |spec| spec["line_number"] }).to all(eq(3))
      expect(specs.map { |spec| [spec["file_path"], spec["line_number"]] }.uniq.length).to eq(1)
    end

    # Criterion 1. Three rows, three identities — so a per-example duration and
    # a per-example outcome each have somewhere to live.
    it "still gives each of the three an id of its own" do
      expect(specs.map { |spec| spec["id"] }.uniq.length).to eq(3)
    end

    # RSpec's own re-run argument, verbatim: `rspec './loop_spec.rb[1:2]'` runs
    # exactly the second case and nothing else. Keeping the `./` prefix is the
    # point — it is what makes the value paste-able rather than merely unique.
    it "makes each id the argument that re-runs that one example" do
      expect(specs.map { |spec| spec["id"] })
        .to eq(["./sample_spec.rb[1:1]", "./sample_spec.rb[1:2]", "./sample_spec.rb[1:3]"])
    end

    it "still names each example distinctly, and still accepts every row" do
      expect(specs.map { |spec| spec["name"] }).to eq(
        ["Order returns 200 for a visa card",
         "Order returns 402 for a expired card",
         "Order returns 403 for a stolen card"]
      )
      violations = specs.each_with_index.flat_map { |spec, index| IngestContract.errors_for(spec, index) }
      expect(violations).to be_empty
    end
  end

  describe "a shared example group run from two different spec files" do
    before(:context) { @run = run_rspec(files: FormatterRunHelpers::SHARED_EXAMPLE_FILES) }

    let(:run) { @run }
    let(:specs) { run.payload["specs"] }

    it "runs both files' worth of examples" do
      expect(run.stdout).to include("4 examples, 0 failures")
      expect(specs.length).to eq(4)
    end

    # The defect, again as a measurement. Four examples, two coordinates — and
    # both coordinates name a file the linter never even scans, because
    # `spec/support/shared.rb` is not a `*_spec.rb`.
    it "reports every one of them as defined in the shared support file" do
      expect(specs.map { |spec| spec["file_path"] }).to all(eq("spec/support/shared.rb"))
      expect(specs.map { |spec| [spec["file_path"], spec["line_number"]] }.uniq.length).to eq(2)
    end

    # Criterion 2, first half.
    it "still gives each of the four an id of its own" do
      expect(specs.map { |spec| spec["id"] }.uniq.length).to eq(4)
    end

    # Criterion 2, second half — and the whole reason `spec_file_path` is a
    # separate field. Without it the two files that actually ran these tests
    # appear nowhere in the payload, so a duration-by-file report attributes all
    # four to a `spec/support/` helper.
    it "names the including spec file as the file that ran each example" do
      expect(specs.map { |spec| spec["spec_file_path"] })
        .to contain_exactly("spec/orders_spec.rb", "spec/orders_spec.rb",
                            "spec/users_spec.rb", "spec/users_spec.rb")
    end

    it "roots each id at the including file too, so re-running one is unambiguous" do
      expect(specs.map { |spec| spec["id"] }).to contain_exactly(
        "./spec/orders_spec.rb[1:1:1]", "./spec/orders_spec.rb[1:1:2]",
        "./spec/users_spec.rb[1:1:1]", "./spec/users_spec.rb[1:1:2]"
      )
    end

    it "still produces a spec entry the platform accepts, for all four" do
      violations = specs.each_with_index.flat_map { |spec, index| IngestContract.errors_for(spec, index) }

      expect(violations).to be_empty
    end

    it "keeps the suite's own exit status and says nothing on stderr" do
      expect(run.exit_status).to eq(0)
      expect(run.stderr).to be_empty
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

  # Criteria 1, 3, 4 and 5, at the only level where the promise they are all
  # variations on can actually be observed: the number the shell reads back.
  #
  # In-process assertions cannot see it. A telemetry failure that escapes a
  # formatter hook takes `RSpec::Core::Runner.run`'s exit code with it, and
  # "the process still exited 0" is a claim about a process. So these run a
  # real `rspec` against a real socket, and check the exit status every time —
  # including in the cases where SpecGuard is the thing that is broken.
  describe "delivering the run to a real endpoint" do
    describe "when the endpoint accepts it" do
      before(:context) do
        StubIngestEndpoint.run(status: 202) do |server|
          @run = run_rspec(FormatterRunHelpers::MIXED_SUITE,
                           prepare: ->(_root) { transport_env(server) })
          @requests = server.requests
        end
      end

      let(:run) { @run }
      let(:request) { @requests.first }

      # Criterion 1.
      it "POSTs the run exactly once" do
        expect(@requests.length).to eq(1)
      end

      it "posts to the platform's path, with a Bearer key and a JSON body" do
        expect(request.path).to eq("/api/v1/ingest")
        expect(request.headers["authorization"]).to eq("Bearer sgk_abc123")
        expect(request.headers["content-type"]).to eq("application/json")
      end

      it "sends the whole run, envelope and every example" do
        expect(request.json).to include("commit_sha" => "0d4a1f2c9b8e7d6a5f4c3b2a1908f7e6d5c4b3a2",
                                        "branch" => "main")
        expect(request.json["specs"].length).to eq(3)
        expect(request.json["duration_seconds"]).to be_a(Float).and be > 0
      end

      # The delivered body is the *whole* claim of this slice: it is what
      # produces a 202 rather than a 400, and it is transcribed from the
      # platform's own validator (see {IngestContract}) rather than assumed.
      it "sends a body the platform's ingest contract accepts" do
        violations = request.json["specs"].each_with_index.flat_map do |spec, index|
          IngestContract.errors_for(spec, index)
        end

        expect(violations).to be_empty
      end

      # Criterion 7, on the envelope rather than the specs. These four rules
      # are `Ingest::Payload`'s own (`validate_commit_sha`, `validate_branch`,
      # `validate_duration_seconds`, `validate_specs`), and every one of them
      # rejects the *whole run* rather than one row.
      it "sends an envelope the platform's ingest contract accepts" do
        body = request.json

        expect(body["commit_sha"]).to be_a(String).and satisfy { |v| !v.strip.empty? }
        expect(body["branch"]).to be_a(String).or be_nil
        expect(body["duration_seconds"]).to be_a(Numeric).and be >= 0
        expect(body["specs"]).to be_an(Array)
      end

      # The local file is the fallback, not a second copy: writing both would
      # double a shared CI sink's contents on every successful run.
      it "writes no local file when the run was delivered" do
        expect(run.lines).to be_empty
      end

      it "says nothing on stderr" do
        expect(run.stderr).to be_empty
      end

      it "leaves the suite's own exit status alone" do
        expect(run.stdout).to include("3 examples, 1 failure, 1 pending")
        expect(run.exit_status).to eq(1)
      end
    end

    # Criterion 3. The whole reason this slice exists: `Net::HTTP` returns
    # these as ordinary values, so the formatter's `rescue` sees nothing at all
    # and a naive implementation loses the run in complete silence.
    {
      400 => "a payload the endpoint refuses",
      401 => "a key the endpoint does not accept",
      500 => "an endpoint that is having a bad day"
    }.each do |status, description|
      describe "when the endpoint answers #{status} — #{description}" do
        before(:context) do
          StubIngestEndpoint.run(status: status) do |server|
            @green = run_rspec(FormatterRunHelpers::GREEN_SUITE,
                               prepare: ->(_root) { transport_env(server) })
            @red = run_rspec(FormatterRunHelpers::MIXED_SUITE,
                             prepare: ->(_root) { transport_env(server) })
          end
        end

        it "still exits 0 for a green suite" do
          expect(@green.stdout).to include("1 example, 0 failures")
          expect(@green.exit_status).to eq(0)
        end

        it "still exits 1 for a failing suite" do
          expect(@red.stdout).to include("3 examples, 1 failure, 1 pending")
          expect(@red.exit_status).to eq(1)
        end

        # Naming the status is the requirement, not decoration: a 401 means
        # "rotate the key" and a 400 means "this gem built a body the platform
        # refused". Those are different people's problems.
        it "warns once on stderr, naming the status code" do
          expect(@green.stderr.scan(/SpecGuard:/).length).to eq(1)
          expect(@green.stderr).to include("HTTP #{status}")
        end

        it "leaves stdout to the human formatter" do
          expect(@green.stdout).not_to include("SpecGuard:")
        end

        # Silent loss becomes recoverable loss. The suite is over by the time
        # anyone reads the warning, so a run discarded here cannot be re-run.
        it "writes the payload to the local fallback rather than dropping it" do
          expect(@green.lines.length).to eq(1)
          expect(@red.payload["specs"].length).to eq(3)
        end
      end
    end

    # Criterion 4. A raised exception takes the same path as a refused
    # response — the caller has one outcome to handle, not two.
    describe "when the request cannot be made at all" do
      before(:context) do
        # Port 1 is privileged and nothing is on it, so the connection is
        # refused immediately; `.invalid` is reserved by RFC 2606 and can never
        # resolve, so no test can accidentally depend on a real host.
        @refused = run_rspec(FormatterRunHelpers::GREEN_SUITE, prepare: lambda { |_root|
          { "SPECGUARD_ENDPOINT" => "http://127.0.0.1:1", "SPECGUARD_API_KEY" => "sgk_abc123",
            "SPECGUARD_COMMIT_SHA" => "abc123", "SPECGUARD_TIMEOUT" => "5" }
        })
        @unresolvable = run_rspec(FormatterRunHelpers::MIXED_SUITE, prepare: lambda { |_root|
          { "SPECGUARD_ENDPOINT" => "http://specguard.invalid", "SPECGUARD_API_KEY" => "sgk_abc123",
            "SPECGUARD_COMMIT_SHA" => "abc123", "SPECGUARD_TIMEOUT" => "5" }
        })
      end

      it "still exits 0 for a green suite when the connection is refused" do
        expect(@refused.stdout).to include("1 example, 0 failures")
        expect(@refused.exit_status).to eq(0)
      end

      it "still exits 1 for a failing suite when the host does not resolve" do
        expect(@unresolvable.stdout).to include("3 examples, 1 failure, 1 pending")
        expect(@unresolvable.exit_status).to eq(1)
      end

      it "warns once and names the underlying error" do
        expect(@refused.stderr.scan(/SpecGuard:/).length).to eq(1)
        expect(@refused.stderr).to match(/Errno::|SocketError/)
      end

      it "falls back to the local file, for both of them" do
        expect(@refused.lines.length).to eq(1)
        expect(@unresolvable.payload["specs"].length).to eq(3)
      end
    end

    # Criterion 6. `Net::HTTP`'s stock 60s open + 60s read is up to two minutes
    # added to every CI run against a hung endpoint, which is squarely against
    # "a 20,000-example run must not be meaningfully slowed". The budget is
    # asserted as wall clock, because that is the thing being promised.
    it "gives up on an endpoint that never answers, within the configured budget" do
      StubIngestEndpoint.run(hang: true) do |server|
        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        run = run_rspec(FormatterRunHelpers::GREEN_SUITE,
                        prepare: ->(_root) { transport_env(server, SPECGUARD_TIMEOUT: "1") })
        elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

        expect(run.exit_status).to eq(0)
        expect(run.stderr).to include("Net::ReadTimeout")
        expect(run.lines.length).to eq(1)
        # Generous against a loaded CI box, and still an order of magnitude
        # under the 120s a default-configured Net::HTTP would have spent.
        expect(elapsed).to be < 30
      end
    end

    # Criterion 5. The throwaway project root is not a git checkout and no
    # provider variable is set, so `commit_sha` really is blank — and
    # `Ingest::Payload#validate_commit_sha` rejects that outright, discarding
    # every example rather than the one empty field. Ten seconds of CI time to
    # be told so is pure loss.
    describe "when the commit cannot be determined" do
      before(:context) do
        StubIngestEndpoint.run(status: 202) do |server|
          @run = run_rspec(FormatterRunHelpers::GREEN_SUITE, prepare: lambda { |_root|
            { "SPECGUARD_ENDPOINT" => server.endpoint, "SPECGUARD_API_KEY" => "sgk_abc123" }
          })
          @requests = server.requests
        end
      end

      it "issues no POST at all" do
        expect(@requests).to be_empty
      end

      it "takes the fallback sink instead" do
        expect(@run.lines.length).to eq(1)
        expect(@run.payload["commit_sha"]).to be_nil
      end

      it "says why, rather than leaving the operator to guess" do
        expect(@run.stderr).to include("the commit could not be determined")
      end

      it "still exits on the suite's own terms" do
        expect(@run.exit_status).to eq(0)
      end
    end

    # Criterion 2, at the process level: no key means no network, full stop.
    # Asserted against a live stub rather than by stubbing `Transport`, because
    # "nothing arrived at a real socket" is the claim, and a subprocess is not
    # somewhere a double can reach anyway.
    it "attempts no HTTP call when there is no API key, and writes the file as before" do
      StubIngestEndpoint.run(status: 202) do |server|
        run = run_rspec(FormatterRunHelpers::GREEN_SUITE,
                        prepare: ->(_root) { { "SPECGUARD_ENDPOINT" => server.endpoint } })

        expect(server.requests).to be_empty
        expect(run.lines.length).to eq(1)
        expect(run.stderr).to be_empty
        expect(run.exit_status).to eq(0)
      end
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
