# frozen_string_literal: true

# The formatter half of the client gem: it watches an RSpec run and records
# every example that finished — its name, where it lives, how long it took and
# how it ended — as one JSON object per run.
#
# == Why this file is not on `require "specguard/rspec"`'s chain
#
# `rspec` is a **development** dependency of this gem, not a runtime one
# (specguard-rspec.gemspec declares exactly one runtime dependency:
# json_schemer). `bin/specguard-lint` loads `specguard/rspec`, and it has to
# keep working for someone who installed the gem to lint annotations on a
# machine with no RSpec at all. Putting `require "rspec/core"` on that chain
# would turn a missing test framework into a broken linter.
#
# So the formatter is opt-in, by its own path:
#
#   # spec/spec_helper.rb
#   require "specguard/rspec/formatter"
#   RSpec.configure { |config| config.add_formatter(SpecGuard::RSpecFormatter) }
#
#   # ...or, equivalently, in .rspec
#   --require specguard/rspec/formatter
#   --format SpecGuard::RSpecFormatter
#   --format progress
#
# The `--require` is not optional in the `.rspec` form: RSpec resolves a
# `--format` argument by constant lookup and only then guesses a file name to
# require, and the name it guesses for this class is `spec_guard/r_spec_formatter`.
#
# spec/specguard/rspec/formatter_loading_spec.rb pins the separation in both
# directions.
require "rspec/core"
require "rspec/core/formatters/base_formatter"
require "json"
require "fileutils"

require_relative "configuration"

module SpecGuard
  # == A NOTE ON CONSTANT RESOLUTION — read this before editing
  #
  # `SpecGuard::RSpec` is *this gem's own namespace*. Inside a `module SpecGuard`
  # body an unqualified `RSpec::Core::Formatters` therefore resolves to
  # `SpecGuard::RSpec::Core::Formatters` and dies with
  # `NameError: uninitialized constant SpecGuard::RSpec::Core` — on the very
  # first line of the class definition, before anything else can go wrong.
  #
  # Every reference to the real RSpec below is consequently top-level-qualified
  # with `::`. It is also why this class is `SpecGuard::RSpecFormatter`, a
  # *sibling* of `SpecGuard::RSpec` rather than a member of it: the sibling name
  # keeps the two namespaces from shadowing each other for readers as well as
  # for the interpreter.
  #
  # == What it captures, and for whom
  #
  # Every example, annotated or not. That is the whole point: SpecGuard's
  # premise is that an unannotated test is an anonymous coordinate, and you
  # cannot report on a gap you never recorded. Filtering to the annotated
  # minority here would make the very first run of a new adopter look empty.
  #
  #   file_path    example.metadata[:file_path], relative to the project root
  #   line_number  example.metadata[:line_number]
  #   name         example.full_description — the composed describe/context/it
  #   duration     example.execution_result.run_time, seconds, per example
  #   outcome      example.execution_result.status — passed / failed / pending
  #
  # `status` and `intent` (the annotation itself) are the next slice's job, and
  # HTTP transport the one after that. This slice's sink is a local JSONL file.
  #
  # == The never-block-CI contract, and why it lives *here*
  #
  # SpecGuard's non-negotiable is that telemetry never fails a build. It is
  # tempting to read that as a property of the *transport* — a rescue around
  # the POST — but RSpec does not sandbox formatters, so it is a property of
  # the **capture layer** too. A raise in any of the three hooks below escapes
  # `RSpec::Core::Runner.run` entirely; RSpec's own exit code is then never
  # returned at all, and the process exits 1. Probed against rspec-core 3.13.6:
  #
  #   hook=example_finished  process_exit=1  rspec's exit status: never reached
  #   hook=stop              process_exit=1  rspec's exit status: never reached
  #   hook=close             process_exit=1  rspec's exit status: never reached
  #
  # In the `close` case the suite had already printed `2 examples, 0 failures`
  # and the process still exited 1 — a green suite turned red by telemetry. A
  # `nil` line number, an unwritable `log/`, a full disk: each of those is
  # somebody's broken build, for tests that all passed.
  #
  # So every hook body runs inside {#never_fail_the_run}, which swallows
  # `StandardError` *and* `ScriptError` (an autoload blowing up is not a
  # StandardError, and a bare rescue would miss it), warns once, and returns.
  # `Interrupt`, `SignalException` and `SystemExit` are deliberately not caught:
  # Ctrl-C must stay Ctrl-C.
  #
  # spec/specguard/rspec/formatter_spec.rb fails if any of those rescues is
  # removed.
  class RSpecFormatter < ::RSpec::Core::Formatters::BaseFormatter
    ::RSpec::Core::Formatters.register self, :example_finished, :stop, :close

    # Prefixed so it is obvious in a CI log which tool is talking, and worded so
    # a reader knows immediately that it is not their tests that broke.
    WARNING_PREFIX = "SpecGuard: test telemetry failed and was skipped"

    # @param output [IO] the stream RSpec hands every formatter. Unused — this
    #   formatter's product is a file, and writing to the shared stream is the
    #   human formatter's job. Accepted because RSpec's constructor contract
    #   says so.
    # @param error_stream [IO] where the one-shot warning goes. Injectable so a
    #   spec can read it back without reassigning `$stderr` globally.
    def initialize(output = nil, error_stream: $stderr)
      super(output)
      @error_stream = error_stream
      @specs = []
      @warned = false
      # Stamped here rather than from a `start` hook on purpose. `:start` is not
      # in this formatter's own registered set — it arrives only because
      # BaseFormatter registered for it — and the wall clock a CI operator cares
      # about includes loading the spec files, which happens before `start`
      # fires. `duration_seconds` is therefore a superset of RSpec's own
      # "Finished in N seconds", not a contradiction of it.
      @started_at = monotonic_now
      @duration_seconds = nil
    end

    # One example finished — passed, failed or pending. Called for every
    # example in the run, in the order they complete.
    def example_finished(notification)
      never_fail_the_run { @specs << capture(notification.example) }
    end

    # The suite is over but the process is still alive. Sealing the duration
    # here rather than in `close` keeps the number from absorbing the time the
    # other formatters spend dumping their summaries.
    def stop(_notification)
      never_fail_the_run { @duration_seconds = elapsed_since_start }
    end

    # Last hook of the run: flush what we captured.
    #
    # `super` restores the output stream's sync setting, which BaseFormatter
    # changed on our behalf at `start` (a notification it registers for, and so
    # one this subclass receives too). Overriding `close` without calling it
    # would leave stdout unbuffered for whatever runs next in the process.
    def close(notification)
      never_fail_the_run do
        @duration_seconds ||= elapsed_since_start
        append(payload)
      end
      never_fail_the_run { super(notification) }
    end

    # The run, as it will be written (and, from the third slice on, POSTed).
    # Public so a caller — or a spec — can inspect what was captured without
    # going anywhere near the filesystem.
    #
    # Key names match the platform's ingest contract
    # (`Ingest::Payload`: commit_sha / branch / duration_seconds / specs) so
    # that adding transport later is a transport change and not a reshaping of
    # everything above it.
    #
    # @return [Hash]
    def payload
      configuration = SpecGuard::RSpec.configuration

      {
        "commit_sha" => configuration.commit_sha,
        "branch" => configuration.branch,
        "duration_seconds" => @duration_seconds,
        "specs" => @specs
      }
    end

    private

    def capture(example)
      metadata = example.metadata || {}
      result = example.execution_result

      {
        "file_path" => relative_path(metadata[:file_path]),
        "line_number" => metadata[:line_number],
        "name" => example.full_description,
        "duration" => result&.run_time,
        # A Symbol here would serialize fine but would compare unequal to the
        # string every consumer reads back out of JSON.
        "outcome" => result&.status&.to_s
      }
    end

    # RSpec reports `./spec/orders_spec.rb` for a file under the working
    # directory and an absolute path for one outside it. Reuse RSpec's own
    # definition of "relative to the project root" rather than inventing a
    # second one, then drop the `./` so the value matches what a linter, a
    # `git diff --name-only` and the platform all use as a file's identity.
    def relative_path(path)
      return nil if path.nil?

      string = path.to_s
      return nil if string.empty?

      (::RSpec::Core::Metadata.relative_path(string) || string).sub(%r{\A\./}, "")
    end

    # Appends one line. Opened in append mode and written with a single call so
    # that two suites sharing an output path (parallel CI shards, say) interleave
    # whole runs rather than halves of one.
    def append(data)
      path = SpecGuard::RSpec.configuration.output_path
      directory = File.dirname(path)
      FileUtils.mkdir_p(directory) unless directory == "." || File.directory?(directory)

      File.open(path, "a") { |file| file.write("#{JSON.generate(data)}\n") }
    end

    # `Errno::*` and `IOError` — the sink's failure modes — are both
    # `StandardError` descendants, so they need no separate clause; they are
    # named in the ticket because they are the *reason* this rescue is here, not
    # because Ruby files them somewhere unusual.
    def never_fail_the_run
      yield
    rescue ScriptError, StandardError => e
      warn_once(e)
      nil
    end

    # Once per run. A formatter that warned per example would bury the failure
    # output of the suite it is supposed to be reporting on under thousands of
    # identical lines — which is its own way of breaking somebody's CI.
    def warn_once(error)
      return if @warned

      @warned = true
      @error_stream.puts("#{WARNING_PREFIX} (#{error.class}: #{error.message}). The test run is unaffected.")
    rescue ScriptError, StandardError
      # The warning stream itself is gone. There is nothing left to say, and
      # saying it is not worth failing the run over.
      nil
    end

    def elapsed_since_start
      (monotonic_now - @started_at).round(6)
    end

    # Monotonic: immune to an NTP correction landing mid-suite, which on the
    # wall clock can produce a negative duration.
    def monotonic_now
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end
  end
end
