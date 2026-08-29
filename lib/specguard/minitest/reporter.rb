# frozen_string_literal: true

require "json"
require "fileutils"

# Configuration and Transport are the framework-free halves of the client
# (env resolution, wire delivery, the never-raise contract); both live under
# the rspec namespace because rspec shipped first, neither contains any RSpec.
# Required here rather than assumed because nothing else loads them on a
# minitest-only consumer's machine.
require_relative "../rspec/configuration"

# The Minitest half of `specguard-ruby`. Everything the RSpec formatter knows
# about the platform — the envelope's field names, the transport's
# never-raise contract, the switch that a missing key is — is framework-free
# knowledge that already lives in `SpecGuard::RSpec::Configuration` and
# `SpecGuard::RSpec::Transport` (both named for the framework that happened to
# ship first, neither containing any RSpec). This adapter contributes only the
# part that is genuinely Minitest's: turning `Minitest::Result` objects into
# the same row shape the RSpec formatter emits, at the moment Minitest hands
# them to a reporter.
#
# It is a duck-typed Minitest reporter (`start` / `record` / `report` /
# `passed?`) rather than a subclass of `Minitest::AbstractReporter`, because
# the composite only ever calls those four and a superclass would add
# assertions about documentation we do not need.
#
# ## Telemetry never fails the suite
#
# The same guarantee the RSpec formatter gives, arrived at the same way: every
# step is wrapped, a failed delivery costs one line on stderr and a line in the
# local sink, and `#passed?` is a constant `true` because Minitest folds it
# into the run's own verdict via `CompositeReporter#passed?` — `all?` over its
# reporters — and a telemetry reporter that could redden a suite would be a
# telemetry reporter somebody deletes.
module SpecGuard
  module Minitest
    class Reporter
      # Rows with no usable location are dropped rather than mangled: a row
      # whose file cannot be named fits no by-file aggregate on the platform
      # and would surface as noise. The RSpec formatter's `capture` makes the
      # equivalent call about a metadata-less example.
      class << self
        # `Dir.pwd` at load time, not per row: a reporter constructed inside a
        # test that changes the working directory would otherwise relativize
        # one suite's rows against two different roots.
        def repo_root
          Dir.pwd
        end
      end

      def initialize(configuration: SpecGuard::RSpec.configuration,
                     transport: nil, output: $stderr,
                     clock: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) })
        @configuration = configuration
        # Injected for the specs; the real thing is built the same way the
        # RSpec formatter builds it, from the same configuration object.
        @transport = transport
        @output = output
        @clock = clock
        @rows = []
        @started_at = nil
        @warned = false
      end

      def start
        @started_at = @clock.call
      end

      # Minitest's `CompositeReporter` calls this before every runnable, and
      # minitest 6 requires it on every reporter in the composite — a duck
      # type without it is not "a reporter that ignores prerecords", it is a
      # crash inside `Runnable#run` that takes the suite's exit code with it,
      # which is the one thing this class may never do. A no-op records
      # nothing: the row this adapter wants is the finished `Result`, not the
      # promise of one.
      def prerecord(_klass, _name); end

      # One `Minitest::Result` in, one wire row out. Guarded rather than
      # trusted for the same reason the RSpec formatter guards `capture`:
      # nothing a result object does while being read may cost the suite its
      # exit code.
      def record(result)
        row = row_for(result)
        @rows << row if row
      rescue ScriptError, StandardError
        nil
      end

      # Minitest calls this after every runnable has reported, on the same
      # reporter — the delivery point. A run that recorded nothing ships
      # nothing, mirroring the RSpec formatter's stance on an empty suite.
      def report
        return if @rows.empty?

        deliver(payload)
      rescue ScriptError, StandardError => e
        warn_once("could not ship test telemetry (#{e.class}: #{e.message}). The test run is unaffected.")
      end

      # Constant by contract — see the class comment. Public because
      # `CompositeReporter#passed?` is `all?` over its reporters and this one
      # must never be the reporter that flips a green suite red.
      def passed?
        true
      end

      private

      # The envelope, in the platform's own field names (`Ingest::Payload`:
      # commit_sha / branch / ci_run_id / duration_seconds / specs) — the same
      # rule the RSpec formatter states at its `#payload`: this gem's settings
      # are named its way, every key in this Hash is named the platform's way,
      # and nothing translates between them.
      def payload
        {
          "commit_sha" => @configuration.commit_sha,
          "branch" => @configuration.branch,
          "ci_run_id" => @configuration.run_id,
          "shard_id" => @configuration.shard_id,
          "duration_seconds" => duration_seconds,
          "specs" => @rows
        }
      end

      # The delivery ladder, in the RSpec formatter's order, with the same two
      # sinks for the same two reasons: no key means the local development
      # record (`local_output_path` — a note that a run happened, not a queue);
      # a refused or failed delivery means the replay queue (`output_path` —
      # the file `specguard-ingest` re-delivers). A blank commit_sha means the
      # platform would refuse the whole run, so it is caught before the wall
      # clock is spent and the run goes to the replay queue. Anything else goes
      # to the transport, whose own contract is that nothing escapes it — a
      # non-success `Result` costs one stderr line and a queued run.
      def deliver(data)
        return append(data, @configuration.local_output_path) if @configuration.api_key.to_s.strip.empty?

        if @configuration.commit_sha.to_s.strip.empty?
          return fall_back(data, "no commit sha could be resolved (set SPECGUARD_COMMIT_SHA)")
        end

        result = (@transport || transport_for).deliver(data)
        return if result.success?

        # The transport's `reason` is already the operator-facing sentence for
        # both a refusal (status, what to do about it, the platform's own
        # words) and a failure (exception class and message) — nothing to add.
        fall_back(data, result.reason)
      end

      def transport_for
        require_relative "../rspec/transport"
        SpecGuard::RSpec::Transport.new(
          endpoint: @configuration.endpoint,
          api_key: @configuration.api_key,
          timeout: @configuration.timeout
        )
      end

      def row_for(result)
        # `source_location` is an Array `["path", line]` on minitest 6 and a
        # "path:line" String on minitest 5 — both are read, because which one
        # a consumer runs is not this gem's to choose.
        location = result.source_location
        file, line =
          if location.is_a?(Array)
            location
          else
            location.to_s.split(":", 2)
          end
        # A row without both halves of a location fits no by-file aggregate
        # and no stable identity; dropped rather than mangled, the same call
        # the RSpec formatter makes about a metadata-less example.
        return nil if file.to_s.strip.empty? || line.to_i.zero?

        file = relative_path(file)
        name = "#{result.klass}##{result.name}"
        {
          # Minitest has no RSpec-style rerun path or nested ids, so the
          # definition site is the identity: stable across runs (which is
          # what the platform's per-test identity needs) and unique per
          # definition (which is what a row needs).
          "id" => "#{file}:#{line}",
          "spec_file_path" => file,
          "file_path" => file,
          "line_number" => line&.to_i,
          "name" => name,
          "duration" => result.time,
          # The platform's three outcomes, mapped from Minitest's questions:
          # a skip is a pending (the suite's own vocabulary for "deliberately
          # not answered"), and a failure and an error are both "failed" —
          # Minitest distinguishes assertion failures from exceptions, the
          # wire contract does not, and inventing a fourth outcome here would
          # be a lie the schema refuses.
          "outcome" => outcome_for(result)
        }
      end

      def outcome_for(result)
        return "pending" if result.skipped?
        return "failed" unless result.passed?

        "passed"
      end

      def relative_path(path)
        root = self.class.repo_root
        return path unless path.start_with?("#{root}/")

        path.delete_prefix("#{root}/")
      end

      def duration_seconds
        return 0.0 if @started_at.nil?

        (@clock.call - @started_at).round(3)
      end

      # One JSON run per line, to whichever file this delivery's outcome
      # warrants (see `#deliver` for which and why).
      def append(data, path)
        FileUtils.mkdir_p(File.dirname(path))
        File.open(path, "a") { |f| f.puts(JSON.generate(data)) }
      rescue ScriptError, StandardError => e
        warn_once("could not write telemetry to #{path} (#{e.class}: #{e.message}). The test run is unaffected.")
      end

      def fall_back(data, reason)
        warn_once("could not deliver test telemetry (#{reason}). Falling back to the replay queue. " \
                  "The test run is unaffected.")
        append(data, @configuration.output_path)
      end

      # Once per process, like the formatter's `warn_once`: fifty failing
      # deliveries is one problem, not fifty lines of it.
      def warn_once(message)
        return if @warned

        @warned = true
        @output.puts("SpecGuard: #{message}")
      end
    end
  end
end
