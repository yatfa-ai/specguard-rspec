# frozen_string_literal: true

require "stringio"
require "tmpdir"
require "minitest"

require "specguard/rspec/transport"
require "specguard/minitest/reporter"

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
            "outcome" => "passed"
          )
        end

        it "maps a skip to the platform's pending, not to a failure" do
          reporter = Reporter.new(configuration: configuration(base_env),
                                  transport: recording_transport.first, output: StringIO.new)
          reporter.record(result(:skipped))
          reporter.report

          expect(reporter.instance_variable_get(:@rows).first["outcome"]).to eq("pending")
        end

        it "maps an assertion failure and a raised error to the same failed outcome" do
          reporter = Reporter.new(configuration: configuration(base_env),
                                  transport: recording_transport.first, output: StringIO.new)
          reporter.record(result(:assertion_failed))
          reporter.record(result(:raised))
          reporter.report

          outcomes = reporter.instance_variable_get(:@rows).map { |row| row["outcome"] }
          expect(outcomes).to eq(%w[failed failed])
        end

        it "reads the path:line String minitest 5 reports, not only the Array 6 does" do
          reporter = Reporter.new(configuration: configuration(base_env),
                                  transport: recording_transport.first, output: StringIO.new)
          reporter.record(result(:passed, location: "#{Reporter.repo_root}/spec/old_test.rb:7"))
          reporter.report

          expect(reporter.instance_variable_get(:@rows).first["file_path"]).to eq("spec/old_test.rb")
        end

        it "drops a result whose location cannot be named rather than mangling it" do
          reporter = Reporter.new(configuration: configuration(base_env),
                                  transport: recording_transport.first, output: StringIO.new)
          reporter.record(result(:passed, location: "no-line-in-it"))
          reporter.report

          expect(reporter.instance_variable_get(:@rows)).to be_empty
        end
      end

      describe "the envelope" do
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
