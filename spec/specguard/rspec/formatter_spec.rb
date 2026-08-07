# frozen_string_literal: true

require "tmpdir"
require "specguard/rspec/formatter"

require_relative "../../support/stub_ingest_endpoint"

# What the formatter captures, where it puts it, and — the part that matters
# most — what it does when any of that goes wrong.
#
# RSpec does not sandbox formatters. A raise in `example_finished`, `stop` or
# `close` escapes `RSpec::Core::Runner.run`, RSpec's own exit code is never
# returned, and the process exits 1 — a green suite turned red by telemetry.
# Every "does not raise" example below therefore fails the moment the
# corresponding rescue is removed, which is the whole point of writing them.
# The process-level half of that proof (real exit codes from a real subprocess)
# lives in formatter_run_spec.rb.
RSpec.describe SpecGuard::RSpecFormatter do
  subject(:formatter) { described_class.new(output, error_stream: errors, annotations: annotations) }

  let(:output) { StringIO.new }
  let(:errors) { StringIO.new }
  let(:sink) { File.join(tmpdir, "log", "test_results.jsonl") }

  # Injected rather than real: what an annotation *is* belongs to
  # annotation_lookup_spec.rb, and resolving one here would make every example
  # below depend on a spec file existing at the path the double reports.
  # Answering nil is "unannotated", which is what every example that does not
  # say otherwise expects.
  let(:annotations) { instance_double(SpecGuard::RSpec::AnnotationLookup, intent_for: nil) }

  let(:intent) do
    { "entity" => "Order", "action" => "checkout",
      "behavior" => "returns 402 payment required on expired card", "layer" => "request" }
  end

  attr_reader :tmpdir

  # Each example gets its own project root, and the global configuration is
  # rebuilt around it — the formatter reads a process-wide singleton, so a spec
  # that leaked its output path would silently redirect every later one.
  #
  # `endpoint` and `api_key` are pinned to nil rather than left alone for the
  # same reason: `Configuration.new` seeds from the *real* ENV, so a developer
  # who happened to export `SPECGUARD_API_KEY` would have every example in this
  # file quietly POSTing somewhere instead of writing the file it asserts on.
  around do |example|
    Dir.mktmpdir do |dir|
      @tmpdir = dir
      SpecGuard::RSpec.reset_configuration!
      SpecGuard::RSpec.configure do |config|
        config.output_path = File.join(dir, "log", "test_results.jsonl")
        config.commit_sha = "0d4a1f2c9b8e7d6a5f4c3b2a1908f7e6d5c4b3a2"
        config.branch = "main"
        # Pinned for the same reason `endpoint` and `api_key` are: `Configuration.new` seeds from
        # the real ENV, and this suite runs inside CI jobs that export `GITHUB_RUN_ID` — so left
        # alone, the envelope examples below would assert against whatever build happened to be
        # running them.
        config.run_id = "gha-1234567890"
        # And `shard_id` for a sharper version of it: this gem's own suite may itself be run under
        # `parallel_tests`, which exports `TEST_ENV_NUMBER` — so unpinned, these examples would
        # pass single-process and fail only when someone ran the suite in parallel.
        config.shard_id = "shard-2"
        config.endpoint = nil
        config.api_key = nil
      end
      example.run
    ensure
      SpecGuard::RSpec.reset_configuration!
    end
  end

  # `rerun_file_path` defaults to `file_path` and `id` is built from it, which is
  # exactly the relationship RSpec itself maintains
  # (`metadata.rb:160`, `metadata.rb:105`) — so the default double is an
  # *ordinary* example, where the owning file and the definition file coincide.
  # The shared-example case, where they diverge, is the one worth passing them
  # apart for.
  def build_example(name: "user when signed in can order an item",
                    file_path: "./spec/orders_spec.rb",
                    line_number: 4,
                    run_time: 0.0109,
                    status: :passed,
                    rerun_file_path: file_path,
                    id: "#{rerun_file_path}[1:1]")
    execution_result = instance_double(RSpec::Core::Example::ExecutionResult,
                                       run_time: run_time, status: status)

    instance_double(RSpec::Core::Example,
                    full_description: name,
                    id: id,
                    metadata: { file_path: file_path, line_number: line_number,
                                rerun_file_path: rerun_file_path },
                    execution_result: execution_result)
  end

  def finish(example)
    formatter.example_finished(instance_double(RSpec::Core::Notifications::ExampleNotification,
                                               example: example))
  end

  def sink_lines
    File.exist?(sink) ? File.readlines(sink, chomp: true) : []
  end

  describe "registration" do
    # Criterion 1's precondition. RSpec only delivers the notifications a
    # formatter registered for, so a hook implemented but not registered is
    # dead code that fails silently — the run completes, the file never appears.
    #
    # `:seed` and `:message` are the odd ones out and are deliberately in the
    # list. This formatter has nothing to say about either.
    #
    # `:seed` is the first notification of a run and is where `#seed` restores
    # the human formatter that registering this one suppressed (SPGD-195). Drop
    # it from this list and that repair becomes dead code — a silent run, exactly
    # as before.
    #
    # `:message` is registered for the sake of the registration itself.
    # `setup_default` installs a `FallbackMessageFormatter` unless some already
    # registered formatter listens for `:message`
    # (`rspec-core-3.13.6 formatters.rb:133-135`), and that fallback then prints
    # every message a second time alongside the formatter `#seed` restores. Drop
    # `:message` here and `#message` becomes dead code *and* the duplication
    # comes back — this list is the only thing that decides whether either hook
    # is ever called.
    it "is registered for the five notifications it implements" do
      registered = RSpec::Core::Formatters::Loader.formatters[described_class]

      expect(registered).to contain_exactly(:example_finished, :stop, :close, :seed, :message)
    end

    it "is a BaseFormatter, so RSpec accepts it as an additional --format" do
      expect(described_class.ancestors).to include(RSpec::Core::Formatters::BaseFormatter)
    end

    # The constant-resolution trap: `SpecGuard::RSpec` is this gem's own
    # namespace, so an unqualified `RSpec::Core` inside `module SpecGuard`
    # resolves to `SpecGuard::RSpec::Core` and raises. If that ever creeps back
    # in, the superclass is the first thing to go wrong.
    it "inherits from the real RSpec's BaseFormatter, not from SpecGuard::RSpec" do
      expect(described_class.superclass).to equal(::RSpec::Core::Formatters::BaseFormatter)
    end
  end

  # The `#seed` hook restores the human formatter that registering this one
  # suppresses (SPGD-195), and it does that by mutating `RSpec.configuration` —
  # the *live, global* one, mid-run. Its real behaviour is pinned in
  # formatter_run_spec.rb, in a real `rspec` process where the output can
  # actually be observed. What these two examples pin instead is *when it
  # declines to act*, which a subprocess cannot show.
  #
  # A stand-in configuration is unavoidable here. The suite running this file
  # already has a `progress` formatter attached, so the hook's "somebody already
  # prints a summary" check would short-circuit every time and an assertion
  # against the real configuration would pass no matter what the guard did.
  # It is injected through the formatter's own `rspec_configuration` rather than
  # by stubbing `::RSpec.configuration`, because rspec-core keeps reading that
  # singleton while the example runs and would ask the double for `dry_run?`.
  describe "#seed" do
    let(:elsewhere) do
      instance_double(::RSpec::Core::Configuration, formatters: registered, default_formatter: "progress")
    end

    before do
      allow(elsewhere).to receive(:add_formatter)
      allow(formatter).to receive(:rspec_configuration).and_return(elsewhere)
    end

    # The guard that keeps this hook inert outside a real run. Every other
    # example in this file drives the hooks in-process against a formatter RSpec
    # never registered; without this check, each `seed` call would bolt a
    # progress formatter onto the suite that is running that very example.
    context "when this formatter is not among the configuration's formatters" do
      let(:registered) { [] }

      it "does not touch the configuration" do
        formatter.seed(nil)

        expect(elsewhere).not_to have_received(:add_formatter)
      end
    end

    # The other side, so the guard above cannot be satisfied by a hook that
    # simply never does anything.
    context "when this formatter is registered and nothing else reports the run" do
      let(:registered) { [formatter] }

      it "restores the configured default formatter" do
        formatter.seed(nil)

        expect(elsewhere).to have_received(:add_formatter).with("progress")
      end
    end

    # The case that separates "somebody will print a summary" from "somebody is
    # reporting the run", and the reason the question is asked in the second
    # form. `--format failures` (`FailureListFormatter`) prints one line per
    # failure and never a summary, so a `dump_summary`-only check read this
    # developer as unserved and added a whole progress run on top of the
    # formatter they had named: 32 bytes of failure list became 427 bytes of
    # dots, backtrace and summary.
    #
    # The real class, not a double, because what is being pinned is a fact about
    # a formatter rspec-core ships — a double would just restate whichever answer
    # this spec was written to expect.
    context "when another formatter reports the run without printing a summary" do
      let(:registered) do
        [formatter, ::RSpec::Core::Formatters::FailureListFormatter.new(StringIO.new)]
      end

      it "leaves the configuration alone" do
        formatter.seed(nil)

        expect(elsewhere).not_to have_received(:add_formatter)
      end
    end
  end

  # `#message` is `RSpec::Core::Formatters::FallbackMessageFormatter` under this
  # class's roof, and it exists because of the registration rather than the other
  # way round: `setup_default` appoints that fallback unless some registered
  # formatter listens for `:message` (`formatters.rb:133-135`), and once `#seed`
  # restores `progress` — which listens for it too — the fallback prints every
  # message a second time. Listening here stops it being appointed, and this
  # method takes over its duty.
  #
  # The end-to-end proof is in formatter_run_spec.rb, where a suite whose
  # `after(:context)` hook raises is diffed against the same suite run without
  # SpecGuard. What these examples pin is the branch, which a subprocess cannot
  # isolate: the stand-in configuration is injected through `rspec_configuration`
  # for the same reason `#seed`'s is.
  describe "#message" do
    let(:notification) do
      ::RSpec::Core::Notifications::MessageNotification.new("An error occurred outside of examples")
    end

    let(:elsewhere) { instance_double(::RSpec::Core::Configuration, formatters: registered) }

    before { allow(formatter).to receive(:rspec_configuration).and_return(elsewhere) }

    # The last-resort case, and the one the fallback used to cover: this
    # formatter is the only listener, so the message has nowhere else to go.
    # Without this, suppressing the fallback would trade a duplicated message for
    # a missing one — which is the same defect as SPGD-195 wearing the opposite
    # sign.
    context "when no other registered formatter handles messages" do
      let(:registered) { [formatter] }

      it "prints the message, exactly as RSpec's fallback would have" do
        formatter.message(notification)

        expect(output.string).to eq("An error occurred outside of examples\n")
      end
    end

    # The duplication case. `progress` handles `:message` via
    # `BaseTextFormatter`, so after `#seed` has restored it there are two
    # candidates and only one may print.
    context "when another registered formatter handles messages" do
      let(:registered) do
        [formatter, ::RSpec::Core::Formatters::ProgressFormatter.new(StringIO.new)]
      end

      it "stays quiet and lets that formatter print it" do
        formatter.message(notification)

        expect(output.string).to be_empty
      end
    end

    # The same inertness guard `#seed` carries. This object only owes anybody a
    # message because RSpec registered it and therefore skipped appointing its
    # own fallback; a formatter RSpec never registered — every other example in
    # this file — owes nothing and must write nothing.
    context "when this formatter is not among the configuration's formatters" do
      let(:registered) { [] }

      it "writes nothing" do
        formatter.message(notification)

        expect(output.string).to be_empty
      end
    end
  end

  describe "#payload" do
    it "carries the run envelope from the configuration" do
      formatter.stop(nil)

      expect(formatter.payload).to include(
        "commit_sha" => "0d4a1f2c9b8e7d6a5f4c3b2a1908f7e6d5c4b3a2",
        "branch" => "main"
      )
    end

    # Without this, a sharded suite has no way to say its N POSTs are one run,
    # and the platform records N `TestRun` rows each holding a fraction of the
    # denominator — a 20,000-example suite reported as ~5,000, attributed to the
    # right commit, with nothing on the dashboard able to show it is partial.
    #
    # The setting is `run_id` and the wire field is `ci_run_id` on purpose: the
    # keys of this Hash are the platform's names, spelled as `TestRun` spells
    # them, and the setting names are this gem's.
    it "names the CI run the shard belongs to, under the platform's own key" do
      formatter.stop(nil)

      expect(formatter.payload).to include("ci_run_id" => "gha-1234567890")
    end

    # The laptop path. A run nobody's CI provider named still ships a complete
    # envelope; the platform reads the nil as "this run is its own run".
    it "sends an explicit null run id rather than omitting the key" do
      SpecGuard::RSpec.configure { |config| config.run_id = nil }
      formatter.stop(nil)

      expect(formatter.payload).to have_key("ci_run_id")
      expect(formatter.payload["ci_run_id"]).to be_nil
    end

    # The other half of the run identity. A CI run id survives a re-run by
    # design (`GITHUB_RUN_ID` is documented as unchanged across attempts), so
    # this is what lets the platform tell a shard reporting for the second time
    # from a shard reporting for the first — and therefore replace its numbers
    # rather than add them.
    it "names which shard of that run this process is" do
      formatter.stop(nil)

      expect(formatter.payload).to include("shard_id" => "shard-2")
    end

    it "sends an explicit null shard id rather than omitting the key" do
      SpecGuard::RSpec.configure { |config| config.shard_id = nil }
      formatter.stop(nil)

      expect(formatter.payload).to have_key("shard_id")
      expect(formatter.payload["shard_id"]).to be_nil
    end

    it "reports a non-negative run duration once the suite has stopped" do
      formatter.stop(nil)

      expect(formatter.payload["duration_seconds"]).to be_a(Float).and be >= 0
    end

    # Criterion 4. The unannotated majority is the population SpecGuard exists
    # to measure; a formatter that filtered here would report an empty first run
    # to every new adopter.
    it "records one entry per example, in the order they finished" do
      3.times { |i| finish(build_example(name: "example #{i}", line_number: i + 1)) }

      expect(formatter.payload["specs"].map { |spec| spec["name"] })
        .to eq(["example 0", "example 1", "example 2"])
    end

    # Criterion 3, at the unit level; formatter_run_spec.rb proves the same
    # thing against a real nested describe/context.
    it "records the name as full_description, verbatim" do
      finish(build_example(name: "user when signed in can order an item"))

      expect(formatter.payload["specs"].first["name"]).to eq("user when signed in can order an item")
    end

    it "records the line number, duration and outcome of each example" do
      finish(build_example(line_number: 42, run_time: 0.0109, status: :failed))

      expect(formatter.payload["specs"].first).to include(
        "line_number" => 42,
        "duration" => 0.0109,
        "outcome" => "failed"
      )
    end

    # A Symbol serializes to a JSON string either way, but leaving it a Symbol
    # here means an in-process consumer compares `:passed` against the `"passed"`
    # every JSON reader hands back, and quietly matches nothing.
    it "records the outcome as a String, not the Symbol RSpec reports" do
      finish(build_example(status: :pending))

      expect(formatter.payload["specs"].first["outcome"]).to eq("pending").and be_a(String)
    end

    describe "file paths" do
      it "strips the ./ prefix RSpec puts on a project-relative path" do
        finish(build_example(file_path: "./spec/orders_spec.rb"))

        expect(formatter.payload["specs"].first["file_path"]).to eq("spec/orders_spec.rb")
      end

      it "relativizes an absolute path that lies under the project root" do
        finish(build_example(file_path: File.join(Dir.pwd, "spec", "orders_spec.rb")))

        expect(formatter.payload["specs"].first["file_path"]).to eq("spec/orders_spec.rb")
      end

      it "leaves a path outside the project root absolute rather than inventing one" do
        finish(build_example(file_path: "/elsewhere/orders_spec.rb"))

        expect(formatter.payload["specs"].first["file_path"]).to eq("/elsewhere/orders_spec.rb")
      end
    end
  end

  # `(file_path, line_number)` is the coordinate of the *code*. Two ordinary
  # suite shapes — a table-driven loop, a shared example group — put several
  # examples on one coordinate, so it cannot be the key. These pin the two
  # fields that can be.
  #
  # What a double can prove here is that the formatter *records* both fields,
  # relativizes them like every other path, and never repurposes the coordinate.
  # It cannot prove that RSpec's real `id` is distinct across a loop, because the
  # double is simply told what to answer — that half is in formatter_run_spec.rb,
  # against a real `rspec` process.
  describe "#payload — example identity" do
    it "records RSpec's own example id" do
      finish(build_example(id: "./spec/orders_spec.rb[1:2]"))

      expect(formatter.payload["specs"].first["id"]).to eq("./spec/orders_spec.rb[1:2]")
    end

    it "keeps one row per example when several share a definition line" do
      3.times { |i| finish(build_example(line_number: 4, id: "./spec/table_spec.rb[1:#{i + 1}]")) }

      expect(formatter.payload["specs"].map { |spec| spec["id"] })
        .to eq(["./spec/table_spec.rb[1:1]", "./spec/table_spec.rb[1:2]", "./spec/table_spec.rb[1:3]"])
      expect(formatter.payload["specs"].map { |spec| spec["line_number"] }).to all(eq(4))
    end

    it "names the spec file that ran the example, not only the one that defined it" do
      finish(build_example(file_path: "./spec/support/shared_examples.rb",
                           rerun_file_path: "./spec/orders_spec.rb"))

      expect(formatter.payload["specs"].first).to include(
        "spec_file_path" => "spec/orders_spec.rb",
        "file_path" => "spec/support/shared_examples.rb"
      )
    end

    # The ordinary case, which is nearly every example: the two coincide, so a
    # consumer that groups by `spec_file_path` groups by the file a reader would
    # have named anyway.
    it "reports the owning file as the definition file for an ordinary example" do
      finish(build_example(file_path: "./spec/orders_spec.rb"))

      expect(formatter.payload["specs"].first["spec_file_path"]).to eq("spec/orders_spec.rb")
    end

    it "strips the ./ prefix off the owning file, exactly as it does for file_path" do
      finish(build_example(file_path: File.join(Dir.pwd, "spec", "orders_spec.rb"),
                           rerun_file_path: "./spec/users_spec.rb"))

      expect(formatter.payload["specs"].first).to include(
        "spec_file_path" => "spec/users_spec.rb",
        "file_path" => "spec/orders_spec.rb"
      )
    end

    # RSpec defaults `:rerun_file_path` for every example it builds, so this is
    # unreachable in a real run — but a null here would silently drop a whole
    # file out of any by-file aggregate, and the definition site is the best
    # answer available.
    it "falls back to the definition file when the metadata carries no owning file" do
      example = instance_double(RSpec::Core::Example,
                                full_description: "user can order an item",
                                id: "./spec/orders_spec.rb[1:1]",
                                metadata: { file_path: "./spec/orders_spec.rb", line_number: 4 },
                                execution_result: instance_double(RSpec::Core::Example::ExecutionResult,
                                                                  run_time: 0.01, status: :passed))
      finish(example)

      expect(formatter.payload["specs"].first["spec_file_path"]).to eq("spec/orders_spec.rb")
    end

    # The annotation is read off the `it` line, so the coordinate has to keep
    # meaning "definition site" however the example got there. A shared example
    # inherits the intent written next to the shared `it`, and repurposing
    # `file_path` to the including file would send the lookup to a line that
    # holds something else entirely.
    it "still asks the lookup about the definition site, not the owning file" do
      finish(build_example(file_path: "./spec/support/shared_examples.rb",
                           rerun_file_path: "./spec/orders_spec.rb",
                           line_number: 12))

      expect(annotations).to have_received(:intent_for)
        .with(file: "spec/support/shared_examples.rb", line: 12)
    end

    # Additive means additive: the seven fields the platform already reads must
    # come out of this change byte-identical for an ordinary example.
    it "leaves every pre-existing field untouched" do
      allow(annotations).to receive(:intent_for).and_return(intent)
      finish(build_example(file_path: "./spec/orders_spec.rb", line_number: 42,
                           run_time: 0.0109, status: :failed))

      expect(formatter.payload["specs"].first).to include(
        "file_path" => "spec/orders_spec.rb",
        "line_number" => 42,
        "name" => "user when signed in can order an item",
        "duration" => 0.0109,
        "outcome" => "failed",
        "status" => "annotated",
        "intent" => intent
      )
    end
  end

  # Criterion 1. `status` is the field whose absence made slice 1's payload a
  # guaranteed 400: `Ingest::Payload#validate_status` appends an error for every
  # spec that lacks it (`payload.rb:115`), and `valid?` requires the error list
  # to be empty (`payload.rb:28`), so the run is rejected whole.
  describe "#payload — status and intent" do
    it "reports an example the lookup resolved as annotated, carrying the intent" do
      allow(annotations).to receive(:intent_for).and_return(intent)
      finish(build_example)

      expect(formatter.payload["specs"].first).to include("status" => "annotated", "intent" => intent)
    end

    it "reports an example the lookup could not resolve as unannotated" do
      finish(build_example)

      expect(formatter.payload["specs"].first).to include("status" => "unannotated", "intent" => nil)
    end

    # `Ingest::Payload` reads intent by key, so a present null and an absent key
    # are equivalent to it (`payload.rb:138`). Writing it is for the human and
    # the archive: it is the difference between "we looked and found nothing"
    # and "this producer does not report annotations" — exactly the ambiguity
    # slice 1's payload could not resolve.
    it "writes the intent key explicitly rather than omitting it" do
      finish(build_example)

      expect(formatter.payload["specs"].first).to have_key("intent")
    end

    # The lookup reads the file off disk, so it must be handed the path the
    # payload records and not RSpec's raw `./`-prefixed metadata — otherwise the
    # coordinate the platform stores and the coordinate the annotation was read
    # from are two different strings that only look alike.
    it "asks about the same file path it records, and the example's own line" do
      finish(build_example(file_path: "./spec/orders_spec.rb", line_number: 42))

      expect(annotations).to have_received(:intent_for).with(file: "spec/orders_spec.rb", line: 42)
    end

    it "resolves each example independently" do
      allow(annotations).to receive(:intent_for).and_return(intent, nil, intent)
      3.times { |i| finish(build_example(line_number: i + 1)) }

      expect(formatter.payload["specs"].map { |spec| spec["status"] })
        .to eq(%w[annotated unannotated annotated])
    end
  end

  describe "the JSONL sink" do
    # Criterion 2. Every example in this block runs with no API key, which is
    # the local-development default, and none of them may reach the network.
    it "attempts no HTTP call at all when there is no API key" do
      allow(SpecGuard::RSpec::Transport).to receive(:new).and_call_original

      finish(build_example)
      formatter.close(nil)

      expect(SpecGuard::RSpec::Transport).not_to have_received(:new)
    end

    it "appends the run as a single JSON object on one line" do
      finish(build_example)
      formatter.stop(nil)
      formatter.close(nil)

      expect(sink_lines.length).to eq(1)
      expect(JSON.parse(sink_lines.first)["specs"].length).to eq(1)
    end

    it "creates the output directory when it does not exist yet" do
      expect { formatter.close(nil) }.to change { File.directory?(File.dirname(sink)) }.to(true)
    end

    # JSONL, not JSON: a second run must not truncate the first.
    it "appends to an existing file rather than replacing it" do
      2.times do
        described_class.new(output, error_stream: errors).tap do |run|
          run.stop(nil)
          run.close(nil)
        end
      end

      expect(sink_lines.length).to eq(2)
      expect(sink_lines).to all(satisfy { |line| JSON.parse(line).key?("specs") })
    end

    it "still writes a well-formed envelope for a run with no examples at all" do
      formatter.stop(nil)
      formatter.close(nil)

      expect(JSON.parse(sink_lines.first)).to include("specs" => [], "branch" => "main")
    end

    # `stop` is where the duration is sealed, but a run that never reaches it
    # must not write a null into a field the platform validates as numeric.
    it "still reports a duration when close is reached without stop" do
      formatter.close(nil)

      expect(JSON.parse(sink_lines.first)["duration_seconds"]).to be_a(Float).and be >= 0
    end
  end

  # Criterion 1, 3 and 4: which sink the run goes to, and what happens when the
  # chosen one does not accept it.
  #
  # The failure half is the reason this slice exists. `Net::HTTP` hands back
  # `Net::HTTPUnauthorized` as an ordinary return value, so a wrong API key
  # raises nothing — and the never-block-CI guard around every hook is a
  # `rescue`. A naive `deliver(payload)` inside it therefore produces no
  # exception, no warning, no log line and no file: the entire run's telemetry
  # gone, silently, which is what SPGD-12's "if the API key is wrong … it logs a
  # warning to stderr" forbids.
  describe "the HTTP sink" do
    def deliver_to(server, status: 202, **overrides)
      SpecGuard::RSpec.configure do |config|
        config.endpoint = server.endpoint
        config.api_key = "sgk_abc123"
        config.timeout = 5
        overrides.each { |key, value| config.public_send(:"#{key}=", value) }
      end

      finish(build_example)
      formatter.stop(nil)
      formatter.close(nil)
      server.requests.first
    end

    it "POSTs the run once when an API key is configured" do
      StubIngestEndpoint.run do |server|
        deliver_to(server)

        expect(server.requests.length).to eq(1)
      end
    end

    it "sends exactly what #payload assembled, to the platform's path" do
      StubIngestEndpoint.run do |server|
        request = deliver_to(server)

        expect(request.path).to eq("/api/v1/ingest")
        expect(request.headers["authorization"]).to eq("Bearer sgk_abc123")
        expect(request.json["specs"].length).to eq(1)
        expect(request.json).to include("commit_sha" => "0d4a1f2c9b8e7d6a5f4c3b2a1908f7e6d5c4b3a2",
                                        "branch" => "main",
                                        "ci_run_id" => "gha-1234567890",
                                        "shard_id" => "shard-2")
      end
    end

    # The point of POSTing at all: the local file is the *fallback*, not a
    # second copy. Writing both would double a shared CI sink's contents for
    # every successful run.
    it "writes no local file when the endpoint accepted the run" do
      StubIngestEndpoint.run do |server|
        deliver_to(server)

        expect(sink_lines).to be_empty
      end
    end

    it "says nothing on stderr when the endpoint accepted the run" do
      StubIngestEndpoint.run do |server|
        deliver_to(server)

        expect(errors.string).to be_empty
      end
    end

    it "honours the configured timeout rather than Net::HTTP's 60 seconds" do
      allow(SpecGuard::RSpec::Transport).to receive(:new).and_call_original

      StubIngestEndpoint.run do |server|
        deliver_to(server, timeout: 3)

        expect(SpecGuard::RSpec::Transport)
          .to have_received(:new).with(hash_including(timeout: 3))
      end
    end

    # Criterion 3. Three statuses, because the *action* each implies is
    # different and a warning that only said "delivery failed" would leave the
    # reader unable to tell which of them they are looking at.
    [400, 401, 500].each do |status|
      context "when the endpoint answers #{status}" do
        it "warns on stderr, naming the status" do
          StubIngestEndpoint.run(status: status) do |server|
            deliver_to(server)

            expect(errors.string).to include(described_class::DELIVERY_WARNING_PREFIX)
            expect(errors.string).to include("HTTP #{status}")
          end
        end

        # The failure sink: silent loss becomes recoverable loss. The suite is
        # over by the time anyone reads the warning, so a run discarded here
        # cannot be re-produced — and `output_path` already exists to support
        # exactly this replay-from-file path.
        it "writes the payload to the local fallback rather than dropping it" do
          StubIngestEndpoint.run(status: status) do |server|
            deliver_to(server)

            expect(sink_lines.length).to eq(1)
            expect(JSON.parse(sink_lines.first)["specs"].length).to eq(1)
          end
        end

        it "does not raise out of close" do
          StubIngestEndpoint.run(status: status) do |server|
            expect { deliver_to(server) }.not_to raise_error
          end
        end

        it "warns once, not once per problem" do
          StubIngestEndpoint.run(status: status) do |server|
            deliver_to(server)

            expect(errors.string.lines.length).to eq(1)
          end
        end

        it "names the fallback file, so the reader knows the run is recoverable" do
          StubIngestEndpoint.run(status: status) do |server|
            deliver_to(server)

            expect(errors.string).to include(SpecGuard::RSpec.configuration.output_path)
          end
        end
      end
    end

    # Criterion 4: a raised exception takes the same path as a refused
    # response. One outcome, one warning, one fallback write.
    describe "when the request cannot be made at all" do
      before do
        SpecGuard::RSpec.configure do |config|
          config.api_key = "sgk_abc123"
          config.endpoint = "http://127.0.0.1:1"
          config.timeout = 1
        end
      end

      it "warns and falls back rather than losing the run" do
        finish(build_example)
        formatter.close(nil)

        expect(errors.string).to include(described_class::DELIVERY_WARNING_PREFIX)
        expect(sink_lines.length).to eq(1)
      end

      it "does not raise out of close" do
        expect { formatter.close(nil) }.not_to raise_error
      end

      it "names the underlying error, so the cause is not a mystery" do
        formatter.close(nil)

        expect(errors.string).to match(/Errno::|SocketError/)
      end
    end

    # Criterion 5's second half, and the reason a pre-flight check is worth
    # having at all. `Ingest::Payload#validate_commit_sha` refuses a blank
    # commit and the controller renders 400, so the run would be discarded
    # whole — every example, not merely the empty field. Spending the run's
    # wall clock to be told that is pure loss.
    describe "when the commit could not be determined" do
      it "does not POST at all" do
        StubIngestEndpoint.run do |server|
          deliver_to(server, commit_sha: nil)

          expect(server.requests).to be_empty
        end
      end

      it "takes the fallback sink and says why" do
        StubIngestEndpoint.run do |server|
          deliver_to(server, commit_sha: nil)

          expect(sink_lines.length).to eq(1)
          expect(errors.string).to include("the commit could not be determined")
        end
      end

      it "treats a blank commit the same as a missing one" do
        StubIngestEndpoint.run do |server|
          deliver_to(server, commit_sha: "   ")

          expect(server.requests).to be_empty
        end
      end
    end

    # A key with nowhere to send it. Answered here rather than deep inside
    # `Net::HTTP`, because "no endpoint is configured" is a sentence somebody
    # can act on and `URI::InvalidURIError` is not.
    describe "when an API key is set but no endpoint is" do
      before { SpecGuard::RSpec.configure { |config| config.api_key = "sgk_abc123" } }

      it "falls back to the file and names the missing setting" do
        formatter.close(nil)

        expect(sink_lines.length).to eq(1)
        expect(errors.string).to include("SPECGUARD_ENDPOINT")
      end
    end

    # The fallback's own failure mode. Both sinks are gone, the run really is
    # lost — but the process must still exit on the suite's own terms, and the
    # one warning the run is allowed must be the specific one.
    it "survives a fallback write that fails too, still naming the HTTP status" do
      StubIngestEndpoint.run(status: 401) do |server|
        blocker = File.join(tmpdir, "blocker")
        File.write(blocker, "not a directory")

        expect { deliver_to(server, output_path: File.join(blocker, "results.jsonl")) }
          .not_to raise_error
        expect(errors.string).to include("HTTP 401")
      end
    end
  end

  # Criterion 5. Each of these fails if its rescue is deleted.
  # The delivery decision that comes before every other one: was anything
  # actually measured?
  #
  # `rspec --dry-run` builds and reports every example without executing a
  # body, so `duration` becomes the cost of construction (~1e-5s) and `outcome`
  # becomes `passed` for code that never ran. Neither field carries a marker
  # saying so, `Ingest::Payload` validates neither, and
  # `Repository#latest_test_run` is last-writer-wins — so a lint job that
  # inherits an environment-level API key replaces the repository's headline
  # with all-green zeroes.
  #
  # Dry-run mode is a property of the process, so these examples stub the one
  # seam that reads it. The end-to-end proof — a real `rspec --dry-run` against
  # a real socket — is in formatter_run_spec.rb.
  describe "refusing to deliver a dry run" do
    def dry_run!(value = true)
      configuration = instance_double(RSpec::Core::Configuration, dry_run?: value)
      allow(formatter).to receive(:rspec_configuration).and_return(configuration)
    end

    # Criterion 5, and the only example here that names the *cause* rather than
    # a downstream symptom.
    #
    # `SpecGuard::RSpec` is this gem's own namespace, so a bare
    # `RSpec.configuration` inside `module SpecGuard` reaches this gem's
    # Configuration — which has no `dry_run?`. Measured by mutating
    # `#rspec_configuration` and running this suite: with the formatter's
    # `respond_to?` guard in place that does not raise, it answers "not a dry
    # run" for every run and silently reinstates the defect the guard exists to
    # close. Five examples fail, four of them process-level ones in
    # formatter_run_spec.rb that can only report the symptom; this is the one
    # that says which line is wrong.
    #
    # (Mutating both — bare `RSpec` *and* no `respond_to?` — is the state the
    # ticket warned about: a swallowed NoMethodError leaving a formatter that
    # delivers nothing at all. That one is not subtle; 84 examples fail.)
    it "reads the real RSpec's configuration, not this gem's same-named one" do
      expect(formatter.send(:rspec_configuration)).to equal(::RSpec.configuration)
    end

    it "is asking a question this gem's own configuration cannot answer" do
      expect(SpecGuard::RSpec.configuration).not_to respond_to(:dry_run?)
      expect(::RSpec.configuration).to respond_to(:dry_run?)
    end

    # The control for everything below: this suite is not itself a dry run, so
    # unstubbed the predicate must be false and delivery must be ordinary.
    it "delivers normally when RSpec is not in dry-run mode" do
      expect(formatter.send(:dry_run?)).to be(false)

      finish(build_example)
      formatter.close(nil)

      expect(sink_lines.length).to eq(1)
    end

    context "when RSpec is in dry-run mode" do
      before { dry_run!(true) }

      it "appends nothing to the local sink" do
        finish(build_example)
        formatter.close(nil)

        expect(sink_lines).to be_empty
      end

      it "issues no POST, even with an API key and an endpoint configured" do
        StubIngestEndpoint.run do |server|
          SpecGuard::RSpec.configure do |config|
            config.endpoint = server.endpoint
            config.api_key = "sgk_abc123"
            config.timeout = 5
          end

          finish(build_example)
          formatter.close(nil)

          expect(server.requests).to be_empty
        end
      end

      it "says so on stderr, exactly once" do
        3.times { finish(build_example) }
        formatter.close(nil)

        expect(errors.string).to include(described_class::DRY_RUN_WARNING_PREFIX)
        expect(errors.string.lines.length).to eq(1)
      end

      # Only the *delivery* decision changes. Capture is left exactly as it
      # was, so a caller — or a future replay path — can still inspect what the
      # run looked like without anything having been written anywhere.
      it "still captures the run, so #payload remains inspectable" do
        finish(build_example)
        formatter.stop(nil)
        formatter.close(nil)

        expect(formatter.payload["specs"].length).to eq(1)
        expect(formatter.payload["duration_seconds"]).to be_a(Float)
      end

      it "does not raise out of close" do
        expect { formatter.close(nil) }.not_to raise_error
      end
    end

    # Criterion 5's second half. An RSpec build without the predicate must fall
    # through to *normal delivery* — the pre-existing behaviour — rather than
    # to a NoMethodError that never_fail_the_run would swallow into silence.
    context "when the RSpec configuration has no #dry_run? at all" do
      before { allow(formatter).to receive(:rspec_configuration).and_return(Object.new) }

      it "treats the run as an ordinary one" do
        expect(formatter.send(:dry_run?)).to be(false)
      end

      it "delivers it, rather than swallowing a NoMethodError into silence" do
        finish(build_example)
        formatter.close(nil)

        expect(sink_lines.length).to eq(1)
        expect(errors.string).to be_empty
      end
    end
  end

  describe "never failing the run" do
    def unwritable_sink!
      blocker = File.join(tmpdir, "blocker")
      File.write(blocker, "not a directory")
      SpecGuard::RSpec.configure { |config| config.output_path = File.join(blocker, "results.jsonl") }
    end

    it "swallows an unwritable output path instead of raising out of close" do
      unwritable_sink!

      expect { formatter.close(nil) }.not_to raise_error
    end

    it "says so on stderr, once, naming the underlying error" do
      unwritable_sink!
      formatter.close(nil)

      expect(errors.string).to include(described_class::WARNING_PREFIX)
      expect(errors.string).to match(/Errno::/)
    end

    it "swallows a sink that raises IOError" do
      allow(File).to receive(:open).and_call_original
      allow(File).to receive(:open).with(sink, "a").and_raise(IOError, "closed stream")

      expect { formatter.close(nil) }.not_to raise_error
      expect(errors.string).to include("IOError")
    end

    # A bare `rescue` catches StandardError only. An autoload or a mixin
    # blowing up raises ScriptError, and would sail straight past it.
    it "swallows a ScriptError, which a bare rescue would miss" do
      allow(File).to receive(:open).and_call_original
      allow(File).to receive(:open).with(sink, "a").and_raise(NotImplementedError, "nope")

      expect { formatter.close(nil) }.not_to raise_error
      expect(errors.string).to include("NotImplementedError")
    end

    it "swallows an example whose metadata cannot be read" do
      broken = build_example
      allow(broken).to receive(:full_description).and_raise("boom")

      expect { finish(broken) }.not_to raise_error
    end

    # One bad example must not cost the run the other nineteen thousand.
    it "keeps capturing the examples that follow a broken one" do
      broken = build_example
      allow(broken).to receive(:full_description).and_raise("boom")

      finish(broken)
      finish(build_example(name: "the one after"))

      expect(formatter.payload["specs"].map { |spec| spec["name"] }).to eq(["the one after"])
    end

    it "swallows a clock failure in stop" do
      allow(formatter).to receive(:monotonic_now).and_raise("no clock")

      expect { formatter.stop(nil) }.not_to raise_error
    end

    # `seed` is the newest hook and the only one that reaches into
    # `RSpec.configuration` mid-run, so it has a failure mode the others do not:
    # `add_formatter` raises for a formatter name RSpec cannot resolve, which a
    # user with `config.default_formatter = "typo"` supplies. RSpec itself never
    # hits that line — it only adds the default when no formatter was registered
    # at all — so this repair is where such a typo first becomes an exception,
    # and `:seed` is dispatched from `Reporter#start`, before a single example
    # has run. Unguarded, a one-word config typo would abort the whole suite.
    it "swallows a failure while restoring the default formatter" do
      allow(formatter).to receive(:restore_suppressed_default_formatter).and_raise("no such formatter")

      expect { formatter.seed(nil) }.not_to raise_error
      expect(errors.string).to include(described_class::WARNING_PREFIX)
    end

    # `message` reaches into `RSpec.configuration` for the same reason `seed`
    # does, and it is dispatched from a worse place: `reporter.message` carries
    # non-example exceptions and "No examples found.", and the first of those can
    # arrive before `Reporter#report` is even entered. A raise here would replace
    # the error the developer was being told about with one from the telemetry
    # gem.
    it "swallows a failure while relaying a message" do
      allow(formatter).to receive(:relay_message).and_raise("no configuration")

      expect { formatter.message(nil) }.not_to raise_error
      expect(errors.string).to include(described_class::WARNING_PREFIX)
    end

    # Criterion 6, extended to slice 2's code path. The annotation lookup reads
    # files off disk and compiles a JSON Schema, so it has failure modes the
    # rest of the capture layer does not — an unreadable spec file, a spec file
    # that is not valid UTF-8, a vendored schema that will not load.
    #
    # These are guarded *inside* `capture` rather than only by the envelope
    # around `example_finished`, and the difference is the whole point: the
    # outer envelope would drop the example entirely, so a project whose schema
    # failed to load would report a suite with no tests in it. Here it reports
    # a suite with no annotations in it, which is both true and recoverable.
    describe "when the annotation lookup itself fails" do
      before { allow(annotations).to receive(:intent_for).and_raise(broken_lookup) }

      let(:broken_lookup) { SpecGuard::RSpec::SchemaError.new("could not load schema") }

      it "does not raise out of example_finished" do
        expect { finish(build_example) }.not_to raise_error
      end

      it "still records the example, as unannotated" do
        finish(build_example(name: "can order an item"))

        expect(formatter.payload["specs"].first).to include(
          "name" => "can order an item", "status" => "unannotated", "intent" => nil
        )
      end

      # The fields the platform actually stores a run on. Losing an annotation
      # is a gap in one row; losing these is losing the example.
      it "still records the example's outcome and duration" do
        finish(build_example(run_time: 0.0109, status: :failed))

        expect(formatter.payload["specs"].first).to include("duration" => 0.0109, "outcome" => "failed")
      end

      it "says so on stderr exactly once, however many examples are affected" do
        50.times { finish(build_example) }

        expect(errors.string.scan(described_class::WARNING_PREFIX).length).to eq(1)
        expect(errors.string).to include("SchemaError")
      end

      it "records all 50 of them anyway" do
        50.times { finish(build_example) }

        expect(formatter.payload["specs"].length).to eq(50)
      end

      # A ScriptError from the lookup would sail past a bare `rescue`.
      it "swallows a ScriptError from the lookup too" do
        allow(annotations).to receive(:intent_for).and_raise(NotImplementedError, "nope")

        expect { finish(build_example) }.not_to raise_error
        expect(formatter.payload["specs"].first["status"]).to eq("unannotated")
      end

      it "does NOT swallow an interrupt raised from the lookup" do
        allow(annotations).to receive(:intent_for).and_raise(Interrupt)

        expect { finish(build_example) }.to raise_error(Interrupt)
      end
    end

    # A warning per example would bury the failure output of the suite it is
    # supposed to be reporting on.
    it "warns exactly once however many things go wrong" do
      broken = build_example
      allow(broken).to receive(:full_description).and_raise("boom")
      3.times { finish(broken) }
      unwritable_sink!
      formatter.close(nil)

      expect(errors.string.scan(described_class::WARNING_PREFIX).length).to eq(1)
    end

    it "writes nothing to the shared output stream, whatever happens" do
      unwritable_sink!
      finish(build_example)
      formatter.close(nil)

      expect(output.string).to be_empty
    end

    # Ctrl-C must stay Ctrl-C. Reporting an interrupt as "telemetry failed" is
    # its own small lie, and would make a long suite harder to stop.
    it "does NOT swallow an interrupt" do
      allow(File).to receive(:open).and_call_original
      allow(File).to receive(:open).with(sink, "a").and_raise(Interrupt)

      expect { formatter.close(nil) }.to raise_error(Interrupt)
    end
  end
end
