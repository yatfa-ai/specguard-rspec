# frozen_string_literal: true

require "stringio"
require "tmpdir"
require "minitest"

require "specguard/rspec/transport"
require "specguard/minitest/reporter"
require_relative "../../support/validator_stub"

# The Minitest adapter's unit contract: what a `::Minitest::Result` becomes on
# the wire, and what never happens (a raise, a red suite, a second warning).
# The end-to-end chain — plugin discovery, a real child run, a real POST — is
# plugin_spec.rb's business; nothing here starts a process or a server.
module SpecGuard
  module Minitest
    ::RSpec.describe Reporter do
      let(:base_env) do
        {
          "SPECGUARD_ENDPOINT" => "https://specguard.example.test",
          "SPECGUARD_API_KEY" => "sgk_unit",
          "SPECGUARD_COMMIT_SHA" => "1" * 40,
          "SPECGUARD_BRANCH" => "main",
          "SPECGUARD_RUN_ID" => "42"
        }.freeze
      end

      def configuration(env)
        SpecGuard::RSpec::Configuration.new(env: env)
      end

      # A real `::Minitest::Result`, built the way Minitest builds them — through
      # the same failure objects its own reporters see, so the outcome mapping
      # is exercised against `Result#passed?`/`#skipped?` rather than a stand-in
      # that agrees with the adapter by construction.
      # `location` takes either shape `Result#source_location` has across
      # minitest versions: the Array minitest 6 reports (the default here,
      # because that is what a consumer's modern suite sends) or the
      # "path:line" String minitest 5 reports.
      def result(outcome, klass: "FooTest", name: "test_bar", location: nil, time: 0.25)
        location ||= ["#{Reporter.repo_root}/spec/foo_test.rb", 12]
        result = ::Minitest::Result.new(name)
        result.klass = klass
        result.source_location = location
        result.time = time
        result.failures =
          case outcome
          when :passed then []
          when :skipped then [::Minitest::Skip.new("deliberately not answered")]
          when :assertion_failed then [::Minitest::Assertion.new("expected 1, got 2")]
          when :raised then [::Minitest::UnexpectedError.new(StandardError.new("boom"))]
          else raise outcome.to_s
          end
        result
      end

      def recording_transport(outcome: :success)
        captured = nil
        transport = Object.new
        transport.define_singleton_method(:deliver) do |data|
          captured = data
          SpecGuard::RSpec::Transport::Result.new(outcome: outcome,
            code: outcome == :success ? 202 : 400)
        end
        [transport, -> { captured }]
      end

      describe "row mapping" do
        # @intent: { entity: "Minitest Reporter", action: "map a passed result", behavior: "a passing minitest result becomes a row with the platform field names, file and line split from the source location, and the recorded duration", layer: "unit" }
        it "maps a passed result to a passed row in the platform's field names" do
          reporter = Reporter.new(configuration: configuration(base_env),
                                  transport: recording_transport.first, output: StringIO.new)
          reporter.record(result(:passed, time: 1.5))
          reporter.report

          row = reporter.instance_variable_get(:@rows).first
          expect(row).to match(
            "id" => "spec/foo_test.rb:12",
            "spec_file_path" => "spec/foo_test.rb",
            "file_path" => "spec/foo_test.rb",
            "line_number" => 12,
            "name" => "FooTest#test_bar",
            "duration" => 1.5,
            "outcome" => "passed",
            "status" => "unannotated",
            "intent" => nil
          )
        end

        # @intent: { entity: "Minitest Reporter", action: "map a skipped result", behavior: "a skipped result reports the platform pending outcome rather than a failure", layer: "unit" }
        it "maps a skip to the platform's pending, not to a failure" do
          reporter = Reporter.new(configuration: configuration(base_env),
                                  transport: recording_transport.first, output: StringIO.new)
          reporter.record(result(:skipped))
          reporter.report

          expect(reporter.instance_variable_get(:@rows).first["outcome"]).to eq("pending")
        end

        # @intent: { entity: "Minitest Reporter", action: "map failing results", behavior: "an assertion failure and an unexpected raise both map to the same failed outcome", layer: "unit" }
        it "maps an assertion failure and a raised error to the same failed outcome" do
          reporter = Reporter.new(configuration: configuration(base_env),
                                  transport: recording_transport.first, output: StringIO.new)
          reporter.record(result(:assertion_failed))
          reporter.record(result(:raised))
          reporter.report

          outcomes = reporter.instance_variable_get(:@rows).map { |row| row["outcome"] }
          expect(outcomes).to eq(%w[failed failed])
        end

        # @intent: { entity: "Minitest Reporter", action: "read legacy locations", behavior: "a path colon line location string in the minitest five shape splits into file_path and line_number like the array shape does", layer: "unit" }
        it "reads the path:line String minitest 5 reports, not only the Array 6 does" do
          reporter = Reporter.new(configuration: configuration(base_env),
                                  transport: recording_transport.first, output: StringIO.new)
          reporter.record(result(:passed, location: "#{Reporter.repo_root}/spec/old_test.rb:7"))
          reporter.report

          expect(reporter.instance_variable_get(:@rows).first["file_path"]).to eq("spec/old_test.rb")
        end

        # @intent: { entity: "Minitest Reporter", action: "drop unnameable results", behavior: "a result whose location carries no line is dropped from the rows rather than emitted mangled", layer: "unit" }
        it "drops a result whose location cannot be named rather than mangling it" do
          reporter = Reporter.new(configuration: configuration(base_env),
                                  transport: recording_transport.first, output: StringIO.new)
          reporter.record(result(:passed, location: "no-line-in-it"))
          reporter.report

          expect(reporter.instance_variable_get(:@rows)).to be_empty
        end
      end

      describe "annotations" do
        # The real lookup against the real offline validator stub — not a
        # double — because what is under test is precisely the delegation:
        # that the reporter hands the definition-site coordinates to
        # AnnotationLookup and ships whatever verdict comes back. A double
        # here would agree with the reporter by construction.
        def stub_validator_annotations
          SpecGuard::RSpec::AnnotationLookup.new(
            env: { "SPECGUARD_VALIDATE_INTENT" => ValidatorStub.install_stubbable }
              .merge(ValidatorStub.stub_env)
          )
        end

        def annotated_suite(source)
          file = File.join(Dir.mktmpdir, "suite_test.rb")
          File.write(file, source)
          file
        end

        # @intent: { entity: "Minitest Reporter", action: "attach annotations", behavior: "a comment form annotation on the line above the definition marks the row annotated with the parsed intent", layer: "unit" }
        it "attaches a comment-form annotation from the line above the definition" do
          file = annotated_suite(<<~RUBY)
            class OrdersTest < Minitest::Test
              # @intent: { entity: "Order", action: "refund stock", behavior: "a refund restores the stock the order consumed", layer: "unit" }
              def test_restores_stock
                assert_equal 1, 1
              end

              def test_unannotated
                assert_equal 1, 1
              end
            end
          RUBY
          line = File.readlines(file).index { |l| l.include?("def test_restores_stock") } + 1

          reporter = Reporter.new(configuration: configuration(base_env),
                                  transport: recording_transport.first, output: StringIO.new,
                                  annotations: stub_validator_annotations)
          reporter.record(result(:passed, location: [file, line]))
          reporter.report

          row = reporter.instance_variable_get(:@rows).first
          expect(row["status"]).to eq("annotated")
          expect(row["intent"]).to eq(
            "entity" => "Order", "action" => "refund stock",
            "behavior" => "a refund restores the stock the order consumed", "layer" => "unit"
          )
        end

        # @intent: { entity: "Minitest Reporter", action: "attach annotations", behavior: "a trailing form annotation on the definition line itself marks the row annotated", layer: "unit" }
        it "attaches a trailing annotation written on the definition line itself" do
          file = annotated_suite(<<~RUBY)
            class OrdersTest < Minitest::Test
              def test_surfaces_decline # @intent: { entity: "Order", action: "surface decline", behavior: "a declined order surfaces the decline reason to the buyer", layer: "unit" }
                assert_equal 1, 1
              end
            end
          RUBY
          line = File.readlines(file).index { |l| l.include?("def test_surfaces_decline") } + 1

          reporter = Reporter.new(configuration: configuration(base_env),
                                  transport: recording_transport.first, output: StringIO.new,
                                  annotations: stub_validator_annotations)
          reporter.record(result(:passed, location: [file, line]))
          reporter.report

          row = reporter.instance_variable_get(:@rows).first
          expect(row["status"]).to eq("annotated")
          expect(row["intent"]).to include("entity" => "Order", "action" => "surface decline")
        end

        # Criterion 3, at the row level: a malformed annotation is a verdict
        # of nil (the lookup's own downgrade — the linter, not the telemetry,
        # is the tool that fails a build over it), so the row ships
        # unannotated and the suite's verdict is untouched.
        # @intent: { entity: "Minitest Reporter", action: "downgrade malformed annotations", behavior: "a malformed annotation on a row downgrades that row to unannotated and never affects the suite verdict", layer: "unit" }
        it "downgrades a malformed annotation to unannotated and keeps the suite green" do
          file = annotated_suite(<<~RUBY)
            class OrdersTest < Minitest::Test
              # @intent: { entity: "Order",
              def test_typo
                assert_equal 1, 1
              end
            end
          RUBY
          line = File.readlines(file).index { |l| l.include?("def test_typo") } + 1

          reporter = Reporter.new(configuration: configuration(base_env),
                                  transport: recording_transport.first, output: StringIO.new,
                                  annotations: stub_validator_annotations)
          reporter.record(result(:passed, location: [file, line]))
          reporter.report

          row = reporter.instance_variable_get(:@rows).first
          expect(row["status"]).to eq("unannotated")
          expect(row["intent"]).to be_nil
          expect(reporter.passed?).to be(true)
        end

        # The nested envelope: the outer `record` rescue would drop the whole
        # row to learn one annotation, so the lookup runs inside its own and
        # a blow-up costs the row only its annotation.
        # @intent: { entity: "Minitest Reporter", action: "survive lookup failure", behavior: "a failing annotation lookup costs the row its annotation only, warns once, and never affects the suite verdict", layer: "unit" }
        it "ships the row unannotated when the annotation lookup raises" do
          broken = SpecGuard::RSpec::AnnotationLookup.new
          allow(broken).to receive(:intent_for).and_raise(IOError, "spec file vanished")
          output = StringIO.new
          reporter = Reporter.new(configuration: configuration(base_env),
                                  transport: recording_transport.first, output: output,
                                  annotations: broken)
          reporter.record(result(:passed))
          reporter.report

          row = reporter.instance_variable_get(:@rows).first
          expect(row["status"]).to eq("unannotated")
          expect(row["intent"]).to be_nil
          expect(reporter.passed?).to be(true)
          expect(output.string.scan("SpecGuard:").length).to eq(1)
        end

        # The lookup is asked in the platform's own file vocabulary — the
        # relativized path the row ships — with the definition-site line.
        # @intent: { entity: "Minitest Reporter", action: "delegate coordinates", behavior: "the reporter asks the lookup with the relativized file path and the integer line the row carries", layer: "unit" }
        it "asks the lookup with the same file and line the row carries" do
          annotations = instance_double(SpecGuard::RSpec::AnnotationLookup, intent_for: nil)
          reporter = Reporter.new(configuration: configuration(base_env),
                                  transport: recording_transport.first, output: StringIO.new,
                                  annotations: annotations)
          reporter.record(result(:passed))
          reporter.report

          expect(annotations).to have_received(:intent_for)
            .with(file: "spec/foo_test.rb", line: 12)
        end
      end

      describe "the ingestible floor" do
        # The platform rejects a payload whose rows omit `status`
        # (`Ingest::Payload#validate_status` runs per row, and
        # `STATUSES.include?(nil)` is false), and its own E2E capture server
        # cannot see that 400 — so the floor is pinned here, against the
        # envelope the transport is actually handed: every row carries the
        # full nine-key contract, an unannotated row's intent is explicitly
        # null, and status is always the platform's own vocabulary.
        # @intent: { entity: "Minitest Reporter", action: "pin the wire contract", behavior: "every row of a zero annotation envelope carries the full key set with status unannotated and an explicit null intent", layer: "unit" }
        it "carries status and an explicit null intent on every row of an annotation-free envelope" do
          transport, captured = recording_transport
          reporter = Reporter.new(configuration: configuration(base_env),
                                  transport: transport, output: StringIO.new)
          reporter.start
          reporter.record(result(:passed))
          reporter.record(result(:skipped))
          reporter.record(result(:assertion_failed))
          reporter.report

          rows = captured.call["specs"]
          expect(rows.map { |row| row.keys })
            .to all(contain_exactly("id", "spec_file_path", "file_path", "line_number",
                                    "name", "duration", "outcome", "status", "intent"))
          expect(rows.map { |row| row["status"] }).to all(eq("unannotated"))
          expect(rows.map { |row| row["intent"] }).to all(be_nil)
        end

        # The annotated side of the same envelope: `intent` present and
        # schema-valid exactly when status says annotated.
        # @intent: { entity: "Minitest Reporter", action: "pin the wire contract", behavior: "an annotated row carries status annotated with the intent the lookup returned", layer: "unit" }
        it "carries the annotated status and intent together on an annotated row" do
          annotations = instance_double(SpecGuard::RSpec::AnnotationLookup)
          intent = { "entity" => "Order", "action" => "refund stock",
                     "behavior" => "a refund restores the stock the order consumed", "layer" => "unit" }
          allow(annotations).to receive(:intent_for).and_return(intent)
          transport, captured = recording_transport
          reporter = Reporter.new(configuration: configuration(base_env),
                                  transport: transport, output: StringIO.new,
                                  annotations: annotations)
          reporter.start
          reporter.record(result(:passed))
          reporter.report

          row = captured.call["specs"].first
          expect(row).to include("status" => "annotated", "intent" => intent)
        end
      end

      describe "the envelope" do
        # @intent: { entity: "Minitest Reporter", action: "build the envelope", behavior: "the delivered envelope uses the platform wire names, including ci_run_id and shard_id, with duration measured by the injected clock", layer: "unit" }
        it "carries the platform's field names, not this gem's setting names" do
          transport, captured = recording_transport
          reporter = Reporter.new(configuration: configuration(base_env),
                                  transport: transport, output: StringIO.new,
                                  clock: -> { 7.0 })
          reporter.start
          reporter.record(result(:passed))
          reporter.report

          expect(captured.call).to match(
            "commit_sha" => "1" * 40,
            "branch" => "main",
            "ci_run_id" => "42",
            "shard_id" => nil,
            "duration_seconds" => 0.0,
            "specs" => array_including(hash_including("outcome" => "passed"))
          )
        end
      end

      describe "the never-fail guarantee" do
        # @intent: { entity: "Minitest Reporter", action: "fall back to the sink on refusal", behavior: "a rejected delivery appends one line to the configured output path and prints exactly one warning instead of raising", layer: "unit" }
        it "writes the local sink instead of raising when the endpoint refuses" do
          Dir.mktmpdir do |dir|
            sink = File.join(dir, "test_results.jsonl")
            env = base_env.merge("SPECGUARD_OUTPUT_PATH" => sink)
            output = StringIO.new
            reporter = Reporter.new(configuration: configuration(env),
                                    transport: recording_transport(outcome: :rejected).first,
                                    output: output)
            reporter.record(result(:passed))
            expect { reporter.report }.not_to raise_error

            expect(File.exist?(sink)).to be(true)
            expect(File.readlines(sink).length).to eq(1)
            expect(output.string).to include("SpecGuard:")
            # Once, not once per delivery attempt — the run is one problem.
            expect(output.string.scan("SpecGuard:").length).to eq(1)
            expect(reporter.passed?).to be(true)
          end
        end

        # @intent: { entity: "Minitest Reporter", action: "sink silently without a key", behavior: "with no api key configured the reporter writes the local sink file and emits no warning at all", layer: "unit" }
        it "writes the sink without any warning when no key is configured" do
          Dir.mktmpdir do |dir|
            sink = File.join(dir, "test_results.local.jsonl")
            env = base_env.except("SPECGUARD_API_KEY").merge("SPECGUARD_LOCAL_OUTPUT_PATH" => sink)
            output = StringIO.new
            reporter = Reporter.new(configuration: configuration(env),
                                    transport: recording_transport.first, output: output)
            reporter.record(result(:passed))
            reporter.report

            expect(File.exist?(sink)).to be(true)
            expect(output.string).to be_empty
          end
        end

        # @intent: { entity: "Minitest Reporter", action: "never redden the suite", behavior: "a reporter whose delivery was rejected still reports itself passing, so telemetry cannot fail a suite", layer: "unit" }
        it "is always a passing reporter, so telemetry can never redden a suite" do
          reporter = Reporter.new(configuration: configuration(base_env),
                                  transport: recording_transport(outcome: :rejected).first,
                                  output: StringIO.new)
          expect(reporter.passed?).to be(true)
        end
      end
    end
  end
end
