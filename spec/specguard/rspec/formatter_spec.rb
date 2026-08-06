# frozen_string_literal: true

require "tmpdir"
require "specguard/rspec/formatter"

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
  around do |example|
    Dir.mktmpdir do |dir|
      @tmpdir = dir
      SpecGuard::RSpec.reset_configuration!
      SpecGuard::RSpec.configure do |config|
        config.output_path = File.join(dir, "log", "test_results.jsonl")
        config.commit_sha = "0d4a1f2c9b8e7d6a5f4c3b2a1908f7e6d5c4b3a2"
        config.branch = "main"
      end
      example.run
    ensure
      SpecGuard::RSpec.reset_configuration!
    end
  end

  def build_example(name: "user when signed in can order an item",
                    file_path: "./spec/orders_spec.rb",
                    line_number: 4,
                    run_time: 0.0109,
                    status: :passed)
    execution_result = instance_double(RSpec::Core::Example::ExecutionResult,
                                       run_time: run_time, status: status)

    instance_double(RSpec::Core::Example,
                    full_description: name,
                    metadata: { file_path: file_path, line_number: line_number },
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
    it "is registered for the three notifications it implements" do
      registered = RSpec::Core::Formatters::Loader.formatters[described_class]

      expect(registered).to contain_exactly(:example_finished, :stop, :close)
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

  describe "#payload" do
    it "carries the run envelope from the configuration" do
      formatter.stop(nil)

      expect(formatter.payload).to include(
        "commit_sha" => "0d4a1f2c9b8e7d6a5f4c3b2a1908f7e6d5c4b3a2",
        "branch" => "main"
      )
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

  # Criterion 5. Each of these fails if its rescue is deleted.
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
