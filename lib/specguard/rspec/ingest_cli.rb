# frozen_string_literal: true

require "json"
require "optparse"

require_relative "../rspec"
require_relative "transport"

# `specguard-ingest`'s command line — the other end of `log/test_results.jsonl`.
#
# == Why this file is not on `require "specguard/rspec"`'s chain
#
# `specguard-lint` runs on machines that never make a network call, and putting
# this file on the umbrella's chain would put `net/http`, `uri` and `zlib` on
# the linter's load path to serve a command it never invokes. So it is loaded by
# its own path, exactly as the formatter is and for the same reason —
# `require "specguard/rspec/ingest_cli"`, which `bin/specguard-ingest` does.
module SpecGuard
  module RSpec
    # Replays a saved run: reads a `log/test_results.jsonl` back and re-delivers
    # each line through the {Transport} this gem already ships.
    #
    # == The file is not a new wire format, and that is the whole design
    #
    # `SpecGuard::RSpecFormatter#deliver` hands the *same* Hash to
    # `Transport#deliver` and to its own `append`, and each of them calls
    # `JSON.generate` on it once. A line in the sink is therefore byte-for-byte
    # the body the endpoint refused, so replaying it needs no parser, no
    # migration and no versioning — only something that reads a line back and
    # POSTs it. That is all this class is.
    #
    # == The exit contract, which is {CLI}'s reasoning transferred verbatim
    #
    #   0  every line was accepted
    #   1  at least one line was refused by the endpoint
    #   2  this tool could not do its job
    #
    # Ruby exits **1** for an uncaught exception and for an uncaught
    # `OptionParser::InvalidOption`, and 1 is already spent here on "the
    # endpoint said no". Left alone, `specguard-ingest --dry-runn` and an
    # unreadable file would both report that the platform refused a run it was
    # never offered — a tool failure wearing the costume of a content failure,
    # which is the defect {CLI} exists to keep out of the linter. So {#run}
    # rescues and *returns* rather than exits, and {EXIT_REFUSED} is produced in
    # exactly one place — {#exit_code}, over a `:rejected` {Transport::Result} —
    # so it means that and nothing else.
    #
    # `Interrupt`, `SignalException` and `SystemExit` are deliberately not
    # caught. Ctrl-C halfway through a 40-line file must stay Ctrl-C.
    #
    # == Where the line between 1 and 2 actually falls
    #
    # {Transport::Result} already draws it and this class does not redraw it:
    # `:rejected` is *the endpoint answered and said no* — it read the payload,
    # so a verdict about the content exists — and `:failed` is *the endpoint
    # never answered* — connection refused, DNS, TLS, a read timeout. Nothing
    # was delivered on that line and no verdict exists, so it is a 2. A
    # connection refused reported as a 1 would be this tool telling an operator
    # their run is bad on the strength of a socket error.
    #
    # 2 also dominates: a file where line 3 was refused and line 7 never arrived
    # exits 2, because the second fact is the one that leaves work undone. Both
    # are printed either way — the exit code chooses what to shout, never what
    # to say.
    #
    # == It re-delivers EVERY line, and will not guess which ones were failures
    #
    # The sink is not a failure log. `#deliver` writes to it when a delivery
    # failed *and* when no API key was set at all (`return append(data) if
    # blank?(configuration.api_key)`), and the two are indistinguishable on the
    # line — there is no field to tell them apart. A developer's local file is
    # therefore a file of ordinary laptop runs, and pointing this command at it
    # sends all of them.
    #
    # A heuristic here would be worse than the gap: it would be this tool
    # guessing at somebody's intent from data that does not carry it, and being
    # confidently wrong about which runs reach the platform. So the tool is
    # explicit and user-initiated instead, `--help` says so in as many words,
    # and no line is filtered.
    #
    # == What it will not claim
    #
    # The natural question about a replay is whether a line *folded onto* an
    # existing run or *created* a new one, and the platform does not answer it:
    # `Ingest::RunRecorder#record` find-or-creates by `ci_run_id` and the 202
    # body carries no created-versus-updated flag. So this class reports what it
    # can see — the `test_run_id` that came back, and whether the line carried a
    # `ci_run_id` at all — and states folding only where two lines *observed*
    # it: same `ci_run_id` in, same `test_run_id` out is one row, not an
    # inference about one. See {#folding_observations}.
    class IngestCLI
      BANNER = "Usage: specguard-ingest [options] <file>"

      # Shown by `--help`. The second paragraph is the one that has to be there:
      # the sink mixes failed deliveries with ordinary keyless local runs and
      # nothing on the line tells them apart, so a developer must not be able to
      # discover only afterwards that they pushed their laptop's history.
      DESCRIPTION = <<~TEXT.freeze
        Re-delivers a saved run to SpecGuard's ingest endpoint. <file> is a
        log/test_results.jsonl written by the RSpec formatter — one whole run per
        line, byte-for-byte the body the endpoint was offered.

        EVERY line in <file> is delivered. The formatter writes to this file both
        when a delivery failed and when no API key was configured at all, and the
        two are indistinguishable on the line, so a laptop's file is a file of
        ordinary local runs and all of them will be sent. Nothing is filtered and
        nothing is guessed at.

        Each line is delivered once, with no retry, and reported by its line
        number in <file> — so a file that was only partly accepted can be resumed
        rather than blindly re-sent.

        Reads SPECGUARD_ENDPOINT, SPECGUARD_API_KEY and SPECGUARD_TIMEOUT.

        Exit codes:
          0  every line was accepted
          1  at least one line was refused by the endpoint
          2  this tool could not do its job — bad flags, no endpoint or API key,
             an unreadable file, an unparseable line, or a delivery that never
             reached the endpoint
      TEXT

      # Every line in the file was accepted by the endpoint — including the
      # vacuous case of a file with no lines in it, which is loud on stderr for
      # exactly the reason `specguard-lint`'s empty selection is: the contract
      # has no code for "there was nothing to do", so the warning carries it.
      EXIT_OK = 0
      # At least one line was refused. The only code reached by the endpoint
      # having read a payload, and the only path to it is a `:rejected`
      # {Transport::Result}.
      EXIT_REFUSED = 1
      # This tool could not do its job: bad flags, no endpoint or API key
      # configured, a file it could not read, a line it could not parse, or a
      # delivery that never reached the endpoint at all.
      EXIT_MISUSE = 2

      # What happened to one line of the file. `number` is its 1-based position
      # in the file *as given*, counting the blank lines that were skipped, so
      # the report addresses the same lines an editor does and a partially
      # accepted file can be resumed from rather than blindly re-sent.
      LineResult = Struct.new(:number, :status, :detail, :test_run_id, :ci_run_id, keyword_init: true)

      # The file, as this tool reads it: the numbered lines that carry a
      # payload, and a count of the blank ones that do not. The blanks are
      # counted rather than dropped because a summary that quietly narrows what
      # it is summarising is the failure this project keeps finding.
      Source = Struct.new(:path, :lines, :blank, keyword_init: true)

      STATUS_LABELS = {
        accepted: "accepted",
        refused: "refused",
        undelivered: "not delivered",
        unparseable: "unparseable"
      }.freeze

      def initialize(stdout: $stdout, stderr: $stderr, env: ENV)
        @stdout = stdout
        @stderr = stderr
        @env = env
      end

      # @param argv [Array<String>]
      # @return [Integer] 0, 1 or 2 — never anything else, and never by letting
      #   an exception reach the shell
      def run(argv)
        path = parse_options(argv)
        return EXIT_OK if path.nil? # --help / --version already printed

        # Before the file is opened, deliberately. "There is nowhere to send
        # this" is the earlier question — which lines to send does not matter
        # when nothing is going to accept them — and asking it first means an
        # unconfigured run reads its one real problem instead of a complaint
        # about a path that was never the point.
        transport = build_transport

        source = read_source(path)
        results = source.lines.map { |number, text| deliver_line(number, text, transport) }

        report(source, results)
        exit_code(results)
      rescue UsageError => e
        @stderr.puts "specguard-ingest: error: #{e.message}"
        EXIT_MISUSE
      rescue ScriptError, StandardError => e
        # The backstop that makes exit 1 mean one thing. Anything reaching here
        # is a bug in this tool, not a verdict from the endpoint about anyone's
        # run, so it is a 2 and it says so in those words.
        @stderr.puts "specguard-ingest: internal error: #{e.class}: #{e.message}"
        EXIT_MISUSE
      end

      private

      # One expression, over the whole file. The `:undelivered` and
      # `:unparseable` clause is first because 2 dominates: a line that never
      # reached the endpoint leaves the job unfinished, and reporting that as
      # "your content was refused" is the exact confusion the contract exists to
      # prevent.
      def exit_code(results)
        return EXIT_MISUSE if results.any? { |result| %i[undelivered unparseable].include?(result.status) }
        return EXIT_REFUSED if results.any? { |result| result.status == :refused }

        EXIT_OK
      end

      # One line, one attempt, one result — and no retry loop.
      #
      # The gem's no-retry decision is about in-run cost to CI wall clock, and
      # this tool runs out of band where that argument does not apply. It still
      # does not retry: the line is on disk and re-running the command is the
      # retry, made by someone who can see why the first attempt failed rather
      # than by a loop that cannot.
      def deliver_line(number, text, transport)
        payload, problem = parse_payload(text)
        return LineResult.new(number: number, status: :unparseable, detail: problem) if payload.nil?

        ci_run_id = scalar(payload["ci_run_id"])
        result = transport.deliver(payload)

        case result.outcome
        when :success
          LineResult.new(number: number, status: :accepted, detail: "HTTP #{result.code}",
                         test_run_id: result.test_run_id, ci_run_id: ci_run_id)
        when :rejected
          LineResult.new(number: number, status: :refused, detail: result.reason, ci_run_id: ci_run_id)
        else
          LineResult.new(number: number, status: :undelivered, detail: result.reason, ci_run_id: ci_run_id)
        end
      end

      # `[payload, nil]`, or `[nil, problem]` naming why the line is not a run.
      # A pair rather than one value of two types, because `JSON.parse` answers
      # a bare `"text"` line with a String and a sentinel String would then be
      # indistinguishable from a payload — and rather than an exception, because
      # an unparseable line is a per-line result like any other: one corrupt
      # line (a sink truncated by a killed process, most likely) must not stop
      # the other thirty-nine from being delivered.
      def parse_payload(text)
        # Before `JSON.parse`, which raises an encoding error rather than a
        # `JSON::ParserError` for these — and whose message would carry the
        # offending bytes into a `String#strip` that raises in turn.
        return [nil, "the line is not valid UTF-8, so it cannot be a run"] unless text.valid_encoding?

        parsed = JSON.parse(text)
        return [parsed, nil] if parsed.is_a?(Hash)

        [nil, "the line is #{parsed.class} JSON, and a run is an object"]
      rescue JSON::ParserError => e
        [nil, "could not parse the line as JSON: #{e.message.lines.first.to_s.strip}"]
      end

      def build_transport
        configuration = Configuration.new(env: @env)

        # Both named, and named separately. They fail for different reasons and
        # are fixed in different places, and "delivery is not configured" would
        # leave an operator who set one of the two guessing which.
        raise UsageError, "no endpoint is configured (set SPECGUARD_ENDPOINT)" if blank?(configuration.endpoint)
        raise UsageError, "no API key is configured (set SPECGUARD_API_KEY)" if blank?(configuration.api_key)

        transport = Transport.new(endpoint: configuration.endpoint, api_key: configuration.api_key,
                                  timeout: configuration.timeout)
        # Asked once, here, so a malformed `SPECGUARD_ENDPOINT` is one exit 2
        # rather than N identical `:failed` lines. `Transport#deliver` would
        # otherwise swallow the same `ArgumentError` once per line and report a
        # delivery problem for what is a configuration problem.
        validate_endpoint(transport)

        transport
      end

      def validate_endpoint(transport)
        transport.uri
      rescue ArgumentError => e
        raise UsageError, e.message
      end

      # @raise [UsageError] for every way a file can refuse to be read. All of
      #   them are exit 2 — the tool was pointed at something it cannot work
      #   from, which is not a verdict about anybody's run.
      def read_source(path)
        raise UsageError, "no such file: #{path}" unless File.exist?(path)
        raise UsageError, "not a file: #{path}" unless File.file?(path)

        lines = []
        blank = 0

        # Numbered from the file, not from the payloads: a blank line still
        # advances the count, so line 12 in this report is line 12 in an editor.
        #
        # `strip` RAISES on a line that is not valid UTF-8 — pointing this
        # command at a binary file by mistake is the obvious way to get one —
        # and such a line is not blank, it is a line that cannot be a run. It is
        # kept, so {#parse_payload} says exactly that about it and the rest of
        # the file still delivers. Swallowing it here would lose a line silently
        # and letting it raise would report a bug in this tool.
        File.foreach(path).with_index(1) do |text, number|
          if text.valid_encoding? && text.strip.empty?
            blank += 1
          else
            lines << [number, text]
          end
        end

        Source.new(path: path, lines: lines, blank: blank)
      rescue SystemCallError, IOError => e
        raise UsageError, "could not read #{path}: #{e.message}"
      end

      # The per-line report on stdout — it is the product — with the diagnostics
      # about this tool's own situation on stderr, which is the split
      # `specguard-lint` already makes.
      def report(source, results)
        if results.empty?
          @stderr.puts "specguard-ingest: warning: #{source.path} holds no runs to deliver" \
                       "#{" (#{source.blank} blank line#{'s' unless source.blank == 1})" if source.blank.positive?}"
          return
        end

        results.each { |result| @stdout.puts line_report(result) }
        @stdout.puts summary_line(source, results)
        folding_observations(results).each { |observation| @stdout.puts observation }
      end

      def line_report(result)
        detail = [result.detail, identity(result)].compact.join(", ")
        line = "line #{result.number}: #{STATUS_LABELS.fetch(result.status)}"
        detail.empty? ? line : "#{line} — #{detail}"
      end

      # The two facts criterion 4 can be stated from: what the endpoint said the
      # run's id is, and whether the line carried a run identity of its own.
      #
      # A line with no `ci_run_id` is reported as having none and nothing more.
      # The platform records such a run as its own row, but that happens inside
      # `RunRecorder` where this tool cannot see it, and a claim it cannot
      # observe is a claim it does not make.
      def identity(result)
        return nil unless result.status == :accepted

        ["test_run_id #{result.test_run_id || '(not reported)'}",
         result.ci_run_id ? "ci_run_id #{result.ci_run_id}" : "no ci_run_id"].join(", ")
      end

      # States how much of the file reached the endpoint, always, and in a form
      # that cannot read as "all clean" when it was "nothing sent": the
      # accepted count is over the total rather than on its own, and every other
      # outcome gets a clause of its own instead of being folded into a
      # remainder the reader has to compute.
      def summary_line(source, results)
        counts = results.group_by(&:status).transform_values(&:length)
        parts = ["specguard-ingest: delivered #{counts.fetch(:accepted, 0)} of " \
                 "#{results.length} run#{'s' unless results.length == 1} from #{source.path}"]

        parts << "#{counts[:refused]} refused" if counts[:refused]
        parts << "#{counts[:undelivered]} could not be delivered" if counts[:undelivered]
        parts << "#{counts[:unparseable]} could not be parsed" if counts[:unparseable]
        parts << "#{source.blank} blank line#{'s' unless source.blank == 1} skipped" if source.blank.positive?

        parts.join("; ")
      end

      # Folding, stated only where it was *seen*.
      #
      # The proposal for this tool asked it to say whether a replayed line
      # folded into an existing run or created a new one, and the 202 body does
      # not carry that flag. What it does carry is the run's id, and two lines
      # that went out with the same `ci_run_id` and came back with the same
      # `test_run_id` are two deliveries onto one row — which is not an
      # inference about folding, it is folding, observed. Anything short of two
      # such lines gets no sentence at all rather than a hedged one.
      def folding_observations(results)
        results
          .select { |result| result.status == :accepted && result.ci_run_id && result.test_run_id }
          .group_by { |result| [result.ci_run_id, result.test_run_id] }
          .filter_map do |(ci_run_id, test_run_id), group|
            next if group.length < 2

            "specguard-ingest: lines #{group.map(&:number).join(', ')} carried ci_run_id #{ci_run_id} and each " \
              "came back with test_run_id #{test_run_id} — the endpoint folded them onto one run"
          end
      end

      def parse_options(argv)
        parser = OptionParser.new do |o|
          o.banner = BANNER
          o.separator ""
          o.separator DESCRIPTION
          o.separator ""
          o.separator "Options:"
          o.on("-v", "--version", "Print the version and exit") do
            @stdout.puts "specguard-rspec #{VERSION}"
            return nil
          end
          o.on("-h", "--help", "Print this help and exit") do
            @stdout.puts o
            return nil
          end
        end

        files = parser.parse(argv)
        raise UsageError, "no file given — #{BANNER}" if files.empty?
        raise UsageError, "one file at a time, got #{files.length}: #{files.join(', ')}" if files.length > 1

        files.first
      rescue OptionParser::ParseError => e
        # Uncaught, this is the likeliest way a user sees a false "the endpoint
        # refused your run": OptionParser raises and Ruby exits 1. Retyping it
        # is what makes a typo'd flag a 2.
        raise UsageError, e.message
      end

      def blank?(value)
        value.nil? || value.to_s.strip.empty?
      end

      # A run identity is whatever the CI provider exported, passed through by
      # `Configuration` as a free-form string. Anything that is not a scalar is
      # not one, and reporting `{"a"=>1}` as a `ci_run_id` would be this tool
      # inventing structure the envelope does not have.
      def scalar(value)
        value.is_a?(String) || value.is_a?(Numeric) ? value.to_s : nil
      end
    end
  end
end
