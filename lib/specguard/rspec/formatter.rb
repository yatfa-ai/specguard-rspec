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
#
# Neither form names a human formatter, and neither has to: see {#seed} for how
# the one RSpec would have installed is kept, why registering this class would
# otherwise take it away, and {#message} for the second listener that keeping it
# would otherwise leave on the stream.
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
require_relative "transport"
# Brings the linter's discovery chain with it (Scanner, Finding, Schema). That
# direction is safe — `specguard/rspec` does not require `rspec/core`, so the
# linter stays loadable without RSpec; it is only the reverse that would break
# packaging.
require_relative "annotation_lookup"

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
  #   id              example.id — this example's identity within the run
  #   spec_file_path  the spec file that *ran* the example, relative to the root
  #   file_path       example.metadata[:file_path], relative to the project root
  #   line_number     example.metadata[:line_number]
  #   name            example.full_description — the composed describe/context/it
  #   duration        example.execution_result.run_time, seconds, per example
  #   outcome         example.execution_result.status — passed / failed / pending
  #   status          "annotated" / "unannotated" — see {AnnotationLookup}
  #   intent          the parsed annotation when annotated, null when not
  #
  # `status` is not decoration: `Ingest::Payload` validates it against a
  # two-value enum for *every* spec and collects the failures globally, so a
  # payload missing the key is not a payload with a gap — it is a 400 with one
  # error per example.
  #
  # == Why `id` and `spec_file_path` exist alongside the coordinate
  #
  # `(file_path, line_number)` is the coordinate of the **code**, not of the
  # **example**, and two entirely ordinary suite shapes put several examples on
  # one coordinate:
  #
  #   * a table-driven loop — `CASES.each { |c| it("...#{c}") { ... } }` writes
  #     the `it` once, so all N examples report the same line;
  #   * a shared example group — every including file reports the coordinate of
  #     `spec/support/shared.rb`, and the file that actually ran the example
  #     appears nowhere at all.
  #
  # Measured on a probe suite of a 3-case loop plus a 2-example shared group
  # included by two files: 7 examples, 3 distinct coordinates. A key that folds
  # three examples onto one row cannot carry a per-example duration, cannot
  # follow one test's outcome across runs, and hands the duplicate-cluster
  # surface rows that look identical because the *key* collapsed them — a
  # manufactured duplicate in the product's headline answer.
  #
  # RSpec already ships the fix. `Example#id` is
  # `"#{metadata[:rerun_file_path]}[#{metadata[:scoped_id]}]"`
  # (rspec-core 3.13.6, `example.rb:117` → `metadata.rb:105`), it is rooted at
  # the *including* file rather than the defining one, and it is also RSpec's
  # own re-run argument — so a row that turns up slow or flaky is directly
  # actionable: `rspec './spec/table_spec.rb[1:2]'`.
  #
  # **`id` is unique within a run, not stable across refactors.** `scoped_id` is
  # positional, so reordering examples changes it — exactly as `line_number`
  # changes when a line is inserted above it. It is the run-local primary key
  # and nothing more; matching one test across runs remains `name` plus file.
  #
  # `spec_file_path` is `metadata[:rerun_file_path]`, which RSpec defaults to
  # the defining file (`metadata.rb:160`) and overrides with the *including*
  # file for a shared example. It is therefore equal to `file_path` for an
  # ordinary example and differs only for a shared one — which is what makes
  # duration-by-file aggregate to the file that ran the test rather than to a
  # `spec/support/` helper.
  #
  # `file_path` and `line_number` keep their existing meaning — the definition
  # site — and are deliberately not repurposed: the annotation lookup reads
  # `@intent:` from exactly that line, so they are the coordinate the intent
  # came from.
  #
  # == Where the run goes
  #
  # `api_key` set  → one `POST <endpoint>/api/v1/ingest`.
  # `api_key` unset → appended to `output_path`, one JSON object per line.
  #
  # The credential is the switch on purpose: local development is then the
  # default and needs no opt-out. See {#deliver} for what happens when the POST
  # does not land.
  #
  # A malformed or schema-invalid annotation is recorded as `unannotated` with a
  # null intent rather than shipped or shouted about; {AnnotationLookup}
  # documents why, and the linter is the half of this gem that tells the author.
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
  # {#seed} was added after that probe and is guarded for the same reason, with
  # the stakes slightly higher: it is dispatched from `Reporter#start`, before
  # any example has run, so a raise there costs the whole suite rather than its
  # exit code.
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
    # `:seed` and `:message` are not hooks this formatter has anything to say
    # about; both are here for the *human* half of the output.
    #
    # `:seed` is the earliest notification of a run, and {#seed} uses it as the
    # moment to repair RSpec's default-formatter suppression.
    #
    # `:message` is registered for the sake of the registration itself.
    # `setup_default` installs a `FallbackMessageFormatter` unless some already
    # registered formatter listens for `:message` (`formatters.rb:133-135`, via
    # `existing_formatter_implements?` → `reporter.registered_listeners`), and
    # that fallback would then print every message a *second* time alongside the
    # formatter {#seed} restores. Listening here suppresses it and takes over its
    # job — see {#message}, which is that same fallback under this class's roof.
    ::RSpec::Core::Formatters.register self, :example_finished, :stop, :close, :seed, :message

    # Prefixed so it is obvious in a CI log which tool is talking, and worded so
    # a reader knows immediately that it is not their tests that broke.
    WARNING_PREFIX = "SpecGuard: test telemetry failed and was skipped"

    # The other half of that: the run was captured fine, the *delivery* did not
    # land. Kept distinct from {WARNING_PREFIX} because the reader's situation
    # is different — nothing was lost, the payload is sitting in a file, and the
    # thing to fix is a key or a URL rather than a broken sink.
    DELIVERY_WARNING_PREFIX = "SpecGuard: could not deliver test telemetry"

    # `Ingest::Payload::STATUSES`, restated. The platform validates every spec
    # against this pair (`payload.rb:17`), so they are the contract and not a
    # local naming choice.
    STATUS_ANNOTATED = "annotated"
    STATUS_UNANNOTATED = "unannotated"

    # The published formatter-protocol methods that mean "this formatter tells a
    # human what the suite did", as opposed to RSpec's own auxiliaries, which
    # speak only about deprecations and timings. {#reports_the_run?} is where
    # this set is justified, and where the `respond_to?` approximation's limits
    # are written down.
    REPORTS_THE_RUN = %i[
      example_started example_passed example_failed example_pending dump_summary
    ].freeze

    # @param output [IO] the stream RSpec hands every formatter. Unused — this
    #   formatter's product is a file, and writing to the shared stream is the
    #   human formatter's job. Accepted because RSpec's constructor contract
    #   says so.
    # @param error_stream [IO] where the one-shot warning goes. Injectable so a
    #   spec can read it back without reassigning `$stderr` globally.
    # @param annotations [AnnotationLookup] resolves each example's `@intent:`.
    #   One per run: it is where the per-file scan is memoized, so sharing it
    #   across the run is what makes the cost O(files) rather than O(examples).
    #
    #   Fully qualified for the same reason every `::RSpec` above is — and it is
    #   the same trap seen from the other side. This class is a *sibling* of
    #   `SpecGuard::RSpec`, not a member, so a bare `AnnotationLookup` here is
    #   looked up as `SpecGuard::RSpecFormatter::AnnotationLookup` and then
    #   `SpecGuard::AnnotationLookup`, neither of which exists — a NameError
    #   raised from a formatter's constructor, which RSpec reports as
    #   "No examples found".
    def initialize(output = nil, error_stream: $stderr,
                   annotations: SpecGuard::RSpec::AnnotationLookup.new)
      super(output)
      @error_stream = error_stream
      @annotations = annotations
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

    # The first notification of the run — and the one hook here that exists for
    # the *human* half of the output rather than the telemetry half.
    #
    # == The defect this repairs
    #
    # RSpec installs its own default formatter only if the user registered no
    # formatter at all (rspec-core 3.13.6,
    # `lib/rspec/core/formatters.rb:127`):
    #
    #   add default_formatter, output_stream if @formatters.empty?
    #
    # Registering *this* formatter makes that list non-empty, so `progress` is
    # never added — and since this formatter's product is a file, the run prints
    # **nothing**. Measured on a two-example suite with one failure: 351 bytes
    # of stdout without SpecGuard, 0 bytes with it. No dots, no failure message,
    # no diff, no `file:line`, no re-run command, and still exit 1. The
    # telemetry was written perfectly; the developer was left blind.
    #
    # It hit exactly the wrong person. The `.rspec` wiring escaped it only
    # because the README spelled it with a second `--format progress` line, and
    # a developer who explicitly chose `--format documentation` was unaffected —
    # so the casualty was the reader who followed the README's first wiring
    # block and customised nothing. (That `--format progress` line is gone from
    # the README now: with this repair in place neither documented form needs
    # it, which is what finally makes the two forms equivalent.)
    #
    # == Why here, and not in the user's `spec_helper`
    #
    # The obvious repair — `config.add_formatter(:progress) if
    # config.formatters.empty?` inside `RSpec.configure` — is wrong, and
    # silently so. `configuration_options.rb:21-25` applies `--require` (i.e.
    # `spec_helper.rb`) *before* `--format`, so at that moment the list is `[]`
    # no matter what the user asked for. Probed directly: with `.rspec` set to
    # `--format documentation`, `config.formatters` still returns `[]` inside
    # the helper. That repair gives the documentation user documentation *and*
    # progress dots.
    #
    # `:seed` is the first notification `Reporter#start` sends
    # (`reporter.rb:92`, ahead of `:start` on :93), and `Reporter#notify` runs
    # `ensure_listeners_ready` — hence `setup_default` — before dispatching
    # anything (`reporter.rb:207-208`). So by the time this runs, RSpec has
    # finished deciding, and the decision can be read rather than predicted.
    # Repairing here rather than in `start` is what keeps the output
    # byte-identical: a formatter added during `:seed` still receives `:start`,
    # and the only *notification* it misses is this one, which is re-sent at the
    # end of the run (`reporter.rb:189`) and is forwarded below regardless.
    #
    # Arriving late is not the only way the restored formatter can diverge from
    # one RSpec installed itself, and the second way cost a review round. By the
    # time it is added, `setup_default` has already decided that nobody handles
    # `:message` and installed a `FallbackMessageFormatter` to cover for it — so
    # the newcomer, which does handle `:message`, became the *second* listener on
    # that notification and every message printed twice. Measured on a suite
    # whose `after(:context)` hook raises: 338 bytes and one error block without
    # SpecGuard, 546 bytes and two with it. {#message} is the fix, and it works
    # by making `setup_default`'s premise true rather than by undoing its
    # conclusion — there is no public way to withdraw a registered listener.
    #
    # == What counts as "the human formatter is missing"
    #
    # Not "the list is empty" — by now `setup_default` has appended RSpec's own
    # `DeprecationFormatter` (and a `ProfileFormatter` under `--profile`). The
    # question is whether any *other* registered formatter will give a human an
    # account of the run, so that is what is asked: does it respond to any of
    # `example_started`, `example_passed`, `example_failed`, `example_pending` or
    # `dump_summary`? See {#reports_the_run?} for why that set, and for what the
    # `respond_to?` approximation can and cannot see.
    #
    # Nothing here touches anything rspec-core marks `@private`: `formatters`,
    # `add_formatter` and `default_formatter` are documented public API, and
    # every method name in that set is part of the published formatter protocol
    # (`formatters/protocol.rb`).
    #
    # `default_formatter` rather than a hard-coded `:progress`, for the same
    # reason: a user who set `config.default_formatter = 'doc'` asked for that,
    # and it is the value rspec-core's own line would have used.
    def seed(notification)
      never_fail_the_run { restore_suppressed_default_formatter(notification) }
    end

    # `RSpec::Core::Formatters::FallbackMessageFormatter`, moved inside this
    # class — the other half of {#seed}'s repair, and the one that stops it
    # printing everything twice.
    #
    # == Why this method has to exist at all
    #
    # `setup_default` ends with (`formatters.rb:133-135`):
    #
    #   unless existing_formatter_implements?(:message)
    #     add FallbackMessageFormatter, output_stream
    #   end
    #
    # Somebody must print `reporter.message` output — a `--seed` banner, "No
    # examples found.", and every non-example exception, since
    # `notify_non_example_exception` routes through it (`reporter.rb:163-170`).
    # `progress` and `documentation` do it via `BaseTextFormatter#message`; when
    # no registered formatter listens for `:message`, RSpec appoints a fallback.
    #
    # Before this method, this class did not listen for `:message`, so the
    # fallback was always appointed — and then {#seed} added `progress`, which
    # listens for it too. Two listeners, one stream, every message twice. A suite
    # whose `after(:context)` hook raises printed its error block once and 338
    # bytes without SpecGuard, and twice and 546 bytes with it.
    #
    # The fallback cannot be withdrawn once appointed: `Reporter#register_listener`
    # has no inverse, and `Configuration#formatters` hands back a `dup`
    # (`configuration.rb:1024-1026`), so deleting from it changes nothing. The
    # repair is therefore to stop it being appointed — this class listens for
    # `:message`, `existing_formatter_implements?(:message)` is true, and the
    # duty lands here instead.
    #
    # == When it actually prints
    #
    # Only when it is the last resort, which is exactly the fallback's own
    # contract: if any *other* registered formatter handles `:message`, that one
    # prints and this stays quiet. So the wirings behave identically to a run
    # without this gem — `progress` prints it under the README's Ruby form once
    # {#seed} has restored it, `documentation` prints it for a developer who
    # asked for documentation, `json` swallows it into its hash exactly as it
    # does on its own, and `--format html` (which has no `message`) gets it from
    # here, just as it would have got it from the fallback.
    #
    # The check is made per message rather than cached, because a message can
    # arrive **before** `:seed`: `Runner#setup` calls `world.announce_filters`,
    # which reports "No examples found." through `reporter.message` before
    # `Reporter#report` is ever entered. In that window this formatter really is
    # the only listener, and it prints — which is what the fallback would have
    # done.
    #
    # `respond_to?` is the public-API approximation of the question rspec-core
    # answers with `registered_listeners(:message)`; {#reports_the_run?}
    # documents how the two can differ. For `:message` specifically they agree
    # across every formatter rspec-core ships, because the only classes that
    # define `message` are the ones that register it.
    def message(notification)
      never_fail_the_run { relay_message(notification) }
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
        deliver(payload)
      end
      never_fail_the_run { super(notification) }
    end

    # The run, as it will be written or POSTed. Public so a caller — or a spec
    # — can inspect what was captured without going anywhere near the
    # filesystem or the network.
    #
    # Key names match the platform's ingest contract
    # (`Ingest::Payload`: commit_sha / branch / ci_run_id / duration_seconds /
    # specs), which is what made adding transport a transport change rather
    # than a reshaping of everything above it. {Transport} sends this Hash
    # verbatim.
    #
    # `ci_run_id` is the field that keeps a sharded suite honest: every shard of
    # one CI run emits the same one, and the platform folds them onto a single
    # `TestRun` instead of recording one row per shard with a quarter of the
    # denominator in it. `nil` here — a laptop run, an unrecognised
    # provider — means "this run is its own run", which is the pre-existing
    # behaviour and is left exactly alone.
    #
    # `shard_id` says *which* slice of that run this is, and it is what makes
    # the fold idempotent. A CI run id survives a re-run by design (GitHub's
    # `GITHUB_RUN_ID` is documented as unchanged across attempts), so without a
    # per-shard key the platform could only add a re-delivered slice, never
    # recognise it, and "re-run failed jobs" would report a suite bigger than
    # the suite. With it, a retried shard replaces its own previous numbers.
    # `nil` is allowed and still counts — see {Configuration::SHARD_ID_KEYS}.
    #
    # The settings are `run_id` / `shard_id` and the wire fields are
    # `ci_run_id` / `shard_id`, deliberately.
    # Configuration names are this gem's own (`SPECGUARD_RUN_ID`, next to
    # `output_path` and `endpoint`); every key in *this* Hash is the platform's,
    # spelled exactly as `TestRun` spells it. That rule is what lets a reader
    # check the envelope against the schema without a translation table — and a
    # run identity that two sides spell differently is one more way to split a
    # run, which is the whole defect this field closes.
    #
    # @return [Hash]
    def payload
      configuration = SpecGuard::RSpec.configuration

      {
        "commit_sha" => configuration.commit_sha,
        "branch" => configuration.branch,
        "ci_run_id" => configuration.run_id,
        "shard_id" => configuration.shard_id,
        "duration_seconds" => @duration_seconds,
        "specs" => @specs
      }
    end

    private

    # {#seed}'s body. Adds RSpec's default formatter when registering this one
    # suppressed it, and hands the newcomer the notification it arrived too late
    # to receive.
    #
    # The `equal?(self)` guard on the first line is not defensive padding: it is
    # what keeps this method inert outside a real run. `spec/.../formatter_spec.rb`
    # drives these hooks in-process against a formatter that RSpec never
    # registered, and without the guard each of those examples would bolt a
    # progress formatter onto the *parent* suite's live configuration. If this
    # object is not in `RSpec.configuration.formatters`, nothing here is its
    # business.
    def restore_suppressed_default_formatter(notification)
      configuration = rspec_configuration
      registered = configuration.formatters
      return unless registered.any? { |formatter| formatter.equal?(self) }
      return if registered.any? { |formatter| reports_the_run?(formatter) }

      configuration.add_formatter(configuration.default_formatter)
      configuration.formatters.each do |formatter|
        next if registered.any? { |already| already.equal?(formatter) }

        formatter.seed(notification) if formatter.respond_to?(:seed)
      end
    end

    # {#message}'s body: print, but only as the last resort.
    #
    # The `equal?(self)` guard is the same inertness guard
    # {#restore_suppressed_default_formatter} carries, for the same reason — this
    # object only owes anybody a message because RSpec registered it and skipped
    # appointing its own fallback. A formatter RSpec never registered (the
    # in-process examples in `spec/.../formatter_spec.rb`) owes nothing and
    # writes nothing.
    def relay_message(notification)
      registered = rspec_configuration.formatters
      return unless registered.any? { |formatter| formatter.equal?(self) }
      return if registered.any? { |formatter| relays_messages?(formatter) }

      output.puts notification.message
    end

    # The live RSpec configuration, behind a method so a spec can hand this
    # object a stand-in. Stubbing `::RSpec.configuration` itself is not an
    # option: rspec-core reads it throughout the example it is running, so the
    # double gets asked things like `dry_run?` and the example dies inside
    # RSpec rather than inside this class.
    def rspec_configuration
      ::RSpec.configuration
    end

    # Whether `formatter` is somebody else's account of the run — i.e. anything
    # but this formatter that will tell a human what the suite did.
    #
    # == Why this set of methods
    #
    # It is the late-run translation of the condition rspec-core evaluates at
    # `formatters.rb:127`, `@formatters.empty?`. That runs *before* RSpec appends
    # its own auxiliaries, so "empty" there means "the user named no formatter";
    # by the time {#seed} can look, the list also holds a `DeprecationFormatter`
    # (and a `ProfileFormatter` under `--profile`). What separates those from
    # every formatter a user can name is that they speak only about deprecations
    # and timings — never about an example, never about the outcome of the run.
    #
    # So the question is asked in exactly those terms. Checked against the
    # formatters rspec-core ships: `progress`, `documentation` and `html` answer
    # on the `example_*` methods, `json` on `dump_summary`, `--format failures`
    # (`FailureListFormatter`) on `example_failed`; `DeprecationFormatter`,
    # `FallbackMessageFormatter` and `ProfileFormatter` answer on none of them.
    #
    # `dump_summary` alone is *not* enough, and shipping it alone was a bug. A
    # suite run with `--format failures` prints one line per failure and no
    # summary, so a `dump_summary`-only question read it as "nobody is reporting"
    # and bolted a whole progress run onto an explicitly chosen formatter — 32
    # bytes of failure list became 427 bytes of dots, backtrace and summary. That
    # is the additive promise broken in the same breath as it is kept.
    #
    # == What `respond_to?` cannot see
    #
    # rspec-core answers the structurally identical question with
    # `@reporter.registered_listeners(notification).any?` (`formatters.rb:207-209`)
    # — *registration*, not method presence. That is the more accurate question
    # and it is deliberately not the one asked here: `registered_listeners` is
    # `@private` (`reporter.rb:51`), and this repair is worth nothing if a minor
    # rspec-core bump can silence a suite with it.
    #
    # The approximation is not free, and it is worth knowing which way it errs. A
    # formatter that *inherits* one of these methods from `BaseTextFormatter`
    # while registering only a subset of notifications reads as an account of the
    # run and never receives one — so the default is not restored and the run is
    # quiet, which is this ticket's own defect one level in. Nothing rspec-core
    # ships is shaped that way (every class that defines one of these registers
    # it), and a third-party formatter would have to inherit `BaseTextFormatter`
    # specifically to avoid printing. The reverse error — a formatter that prints
    # under some other method name, so the default is restored alongside it — is
    # noisy rather than silent, and is the direction to prefer if this ever has
    # to be re-tuned.
    def reports_the_run?(formatter)
      return false if formatter.equal?(self)

      REPORTS_THE_RUN.any? { |method_name| formatter.respond_to?(method_name) }
    end

    # Whether `formatter` is somebody else's `:message` handling — the question
    # {#message} asks before deciding it is the last resort. See {#message}.
    def relays_messages?(formatter)
      !formatter.equal?(self) && formatter.respond_to?(:message)
    end

    # Sink selection, and the fallback that keeps a failed delivery from being
    # a silent one.
    #
    # Called from inside {#never_fail_the_run}, so nothing below has to guard
    # itself against raising — including the fallback `append`, whose own
    # failure modes (unwritable `log/`, full disk) are already covered there.
    #
    # == Why a failure writes the file rather than shrugging
    #
    # "Never block CI" is a promise about the *exit code*, not a licence to
    # discard the run. A 401 with no file left behind loses the whole run's
    # telemetry for a mistake — a rotated key, a typo'd URL — that is fixed in
    # thirty seconds and cannot be re-run afterwards, because the suite is over.
    # Writing the payload to the local sink turns silent loss into recoverable
    # loss, which is the same thing `output_path` already exists for ("supports
    # a future replay-from-file ingestion path").
    def deliver(data)
      configuration = SpecGuard::RSpec.configuration
      return append(data) if blank?(configuration.api_key)

      obstacle = undeliverable_reason(configuration, data)
      return fall_back(data, obstacle) if obstacle

      result = transport_for(configuration).deliver(data)
      return if result.success?

      fall_back(data, result.reason)
    end

    # The checks worth doing *before* spending the run's wall clock on a request
    # whose answer is already known.
    #
    # `commit_sha` is the sharp one: `Ingest::Payload#validate_commit_sha`
    # refuses a blank one and the controller renders 400, so the run would be
    # discarded whole — every example, not merely the empty field. Ten seconds
    # of CI time to be told that is pure loss, and the operator learns more from
    # being told *why* than from being shown the platform's rejection.
    #
    # @return [String, nil] nil when there is nothing standing in the way.
    def undeliverable_reason(configuration, data)
      if blank?(configuration.endpoint)
        return "an API key is set but no endpoint is (set SPECGUARD_ENDPOINT)"
      end

      return unless blank?(data["commit_sha"])

      "the commit could not be determined, and the endpoint rejects a run without one " \
        "(set SPECGUARD_COMMIT_SHA)"
    end

    def fall_back(data, reason)
      # Warned before the write, not after: if the fallback write *also* fails,
      # the outer guard's one allotted warning has already been spent on the
      # more specific message, which is the one naming the status code.
      warn_delivery_failure(reason)
      append(data)
    end

    def transport_for(configuration)
      SpecGuard::RSpec::Transport.new(
        endpoint: configuration.endpoint,
        api_key: configuration.api_key,
        timeout: configuration.timeout
      )
    end

    def blank?(value)
      value.nil? || value.to_s.strip.empty?
    end

    def capture(example)
      metadata = example.metadata || {}
      result = example.execution_result
      file_path = relative_path(metadata[:file_path])
      line_number = metadata[:line_number]

      # Its own envelope, inside the one `example_finished` already provides.
      # The outer one drops the whole example; this one drops only its
      # annotation, so an unreadable spec file or a broken schema costs the run
      # the intent of the examples in it and not the examples themselves. It
      # also routes through {#warn_once}, so the operator hears about it exactly
      # once however many examples are affected.
      intent = never_fail_the_run { @annotations.intent_for(file: file_path, line: line_number) }

      {
        # Not wrapped in `never_fail_the_run`, unlike the annotation lookup
        # above. That guard is there because the lookup does file I/O; this is a
        # memoized string interpolation over a Hash RSpec has already built, and
        # a guard here could only ever add a way to emit an identity-less row
        # silently. The outer guard at `#example_finished` still covers it.
        "id" => example.id,
        # `|| file_path` rather than a bare read: RSpec defaults
        # `:rerun_file_path` for every example it builds, so the fallback is
        # unreachable in a real run — but if a producer ever hands us metadata
        # without it, the definition site is the best answer available and a
        # null would silently drop a whole file out of any by-file aggregate.
        "spec_file_path" => relative_path(metadata[:rerun_file_path]) || file_path,
        "file_path" => file_path,
        "line_number" => line_number,
        "name" => example.full_description,
        "duration" => result&.run_time,
        # A Symbol here would serialize fine but would compare unequal to the
        # string every consumer reads back out of JSON.
        "outcome" => result&.status&.to_s,
        "status" => intent.nil? ? STATUS_UNANNOTATED : STATUS_ANNOTATED,
        # Written explicitly rather than omitted. `Ingest::Payload` accepts
        # either for an unannotated spec (`payload.rb:138` — nil is nil whether
        # the key was absent or null), and a present null is the difference
        # between "we looked and there was no annotation" and "this producer
        # does not report annotations", which is precisely what slice 1's
        # payload could not say.
        "intent" => intent
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
      emit_warning("#{WARNING_PREFIX} (#{error.class}: #{error.message}). The test run is unaffected.")
    end

    # The delivery half, through the same one-shot budget so a run still emits
    # at most one line however many things went wrong. `reason` names the HTTP
    # status when there was one — a 400 and a 401 call for entirely different
    # actions, and a warning that only said "delivery failed" would leave the
    # reader unable to tell which.
    def warn_delivery_failure(reason)
      path = SpecGuard::RSpec.configuration.output_path

      emit_warning("#{DELIVERY_WARNING_PREFIX} (#{reason}). " \
                   "Falling back to #{path}; the test run is unaffected.")
    end

    def emit_warning(line)
      return if @warned

      @warned = true
      @error_stream.puts(line)
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
