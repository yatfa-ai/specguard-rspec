# frozen_string_literal: true

require "json"
require "open3"

module SpecGuard
  module RSpec
    # The opt-in Go validator backend: `validate-intent --source --json`.
    #
    # == What this is, and what it deliberately is not
    #
    # SPGD-96's Definition of Done ends "…and the Ruby gem invoking it for
    # linting … with the Ruby hand-rolled validation logic removed". This file
    # is the first half of that sentence. The second half is **not** done here,
    # and the reason is distribution rather than confidence:
    # `bin/validate-intent-go` is a build artifact in open-test-intent
    # (`.gitignore`), `/dist/` is ignored there with the comment "this repo
    # does not publish them", and this gem's whole premise is that it has *no
    # cross-repo runtime dependency* ({SCHEMA_PATH}). There is no release to
    # depend on. A default-on shell-out would therefore turn every existing
    # user's working linter into `specguard-lint: error: … No such file`.
    #
    # So the backend is **opt-in and off by default**. With
    # `SPECGUARD_VALIDATE_INTENT` unset, {resolve} returns nil and {CLI} runs
    # exactly the code it ran before this file existed — not "a code path that
    # should be equivalent", the same objects.
    #
    # == Why a dedicated seam rather than {Configuration}
    #
    # The originating proposal put this on `Configuration`. That is the wrong
    # object twice over: `Configuration` is the *telemetry* config — its only
    # consumers are `Formatter` and `Transport`, and `CLI` does not reference
    # it at all — so threading the lint backend through it would make the
    # linter depend on the telemetry object solely to read one env var. It also
    # memoizes process-wide (`SpecGuard::RSpec.configuration`), with
    # `reset_configuration!` existing only for tests, which is a poor fit for
    # something a spec wants to vary per example. {CLI} takes an `env:` instead
    # and asks this module, so the seam is one hash away in a test and one
    # method here in production.
    #
    # == The mapping, and the one thing the JSON document does not carry
    #
    # `RunSourceJSON` (open-test-intent, `cmd/validate-intent/report.go`)
    # NORMALIZES the reference's `problem` and `errors` into a single `errors`
    # list, saying so in a comment: "`problem` and `errors` are the same thing
    # to a consumer… `kind` is what tells them apart". {Linter::Result} keeps
    # them apart, and {CLI#report_failure} renders them differently — an em
    # dash on one line for a `problem`, an indented `-> ` line per `reason`.
    #
    # So the split has to be *reconstructed from `kind`*, which is exactly what
    # the Go comment says `kind` is for:
    #
    #   schema                     -> reasons: errors
    #   extraction / parse / read  -> problem: errors.first
    #   no-match                   -> problem, and see below
    #
    # For the three `problem` kinds an `errors` list of any length other than 1
    # is a **contract change**, not something to paper over by joining the
    # strings: the renderer would silently emit one line where the tool meant
    # several. {Runner} raises, and the run exits 2.
    #
    # == `no-match`: the gem's arguments are PATHS, the binary's are GLOBS
    #
    # `bin/validate-intent` expands its arguments with Python's
    # `glob.glob(..., recursive=True)`; `specguard-lint`'s are paths, checked as
    # given (`CLI#select`, `Scanner.scan_file`). Handing a path straight through
    # would silently re-expand it: `spec/fixtures/bracket[1]_spec.rb` becomes a
    # character class, and a file containing `*` becomes a wildcard that may
    # match *other* files. Every path is therefore escaped with {escape_glob},
    # the port of Python's `glob.escape`, so each argument matches exactly the
    # file it names or nothing at all.
    #
    # "Or nothing at all" is Go's `no-match` kind, which the gem has no
    # `Finding::KIND_*` for. It is mapped to {Finding::KIND_READ}, because that
    # is what it *means* on the gem's side of the seam: a named path that could
    # not be opened. The classification, the dropped line number, the "N files
    # could not be read" clause of the summary and the exit code all follow the
    # Ruby path exactly. Two things about it are deliberate:
    #
    #   * the reported file is the ORIGINAL path, not the escaped pattern —
    #     `[[]1]` is an artifact of this file and printing it would misreport
    #     what the caller asked for;
    #   * the wording is the gem's own, not Go's `no file(s) match <pattern>`,
    #     which is a statement about a *pattern* — a concept `specguard-lint`
    #     does not have, and whose text would carry the escaped form.
    #
    # This is one of the two enumerated text differences between the backends;
    # both are asserted in `spec/specguard/rspec/validator_backend_spec.rb` and
    # in open-test-intent's `tests/parity/run_ruby_parity.sh` under "the Go
    # backend". The other is the read-failure tail — see {Scanner.scan_text},
    # which records why the gem emits a fixed string where CPython and the port
    # emit a decoder diagnostic.
    #
    # == Everything that can go wrong here is exit 2
    #
    # A missing binary, a binary that will not execute, a non-zero exit this
    # cannot read a document out of, or unparseable output are all "the linter
    # could not do its job". They must never reach exit 1, which the contract
    # has already spent on "an annotation is malformed" ({CLI}). Hence
    # {ValidatorError}, rescued beside {UsageError} so the message reads
    # `specguard-lint: error: …` rather than the backstop's `internal error:`.
    module ValidatorBackend
      # Set it to a `validate-intent` binary to route linting through the Go
      # port. Blank or unset means the Ruby path, which is the default and the
      # only behaviour any existing user has.
      ENV_VAR = "SPECGUARD_VALIDATE_INTENT"

      # @param env [Hash, ENV]
      # @return [Runner, nil] nil when the backend is not requested
      # @raise [ValidatorError] when it is requested and unusable
      def self.resolve(env: ENV)
        # Blank means unset, following `Configuration`'s `blank_to_nil` idiom:
        # `SPECGUARD_VALIDATE_INTENT=` in a CI environment file is somebody
        # turning the backend *off*, not asking for a binary named "".
        path = env[ENV_VAR].to_s.strip
        return nil if path.empty?

        Runner.new(path).tap(&:verify!)
      end

      # Python's `glob.escape` for POSIX paths: wrap each of `*`, `?` and `[`
      # in a character class, which makes it match itself literally. `]` is not
      # escaped and does not need to be — outside a class it is already a
      # literal — and CPython does not escape it either.
      #
      # @param path [String]
      # @return [String] a glob pattern matching exactly `path`
      def self.escape_glob(path)
        path.gsub(/([*?\[])/, '[\1]')
      end

      # Invokes the binary and turns its report into {Linter::Result}s.
      class Runner
        # `kind` -> the gem's equivalent. `no-match` has no equivalent of its
        # own and folds into KIND_READ; see the module comment.
        KINDS = {
          "schema" => Finding::KIND_SCHEMA,
          "extraction" => Finding::KIND_EXTRACTION,
          "parse" => Finding::KIND_PARSE,
          "read" => Finding::KIND_READ,
          "no-match" => Finding::KIND_READ
        }.freeze

        # Kinds that are a statement about a FILE rather than about an
        # annotation site. They contribute nothing to `summary.annotations`,
        # exactly as `CLI#summary_line` keeps unread files out of the gem's own
        # annotation count.
        NON_ANNOTATION_KINDS = %w[read no-match].freeze

        # A full audit passes every spec file in the repository — thousands of
        # arguments on a large suite — and `execve` fails with E2BIG somewhere
        # north of 128 KiB on Linux, less elsewhere. Batch well under it. The
        # batches are an implementation detail: {#check} concatenates their
        # findings in argument order, so the caller still gets one list and
        # {CLI} still prints one selection line and one summary line.
        MAX_ARG_BYTES = 96 * 1024
        # A second, independent bound. Some kernels cap the argument *count*
        # (and `MAX_ARG_BYTES` alone would allow ~90k one-character paths).
        MAX_BATCH_FILES = 1_000

        attr_reader :path

        # @param path [String] the `validate-intent` binary
        def initialize(path)
          @path = path
        end

        # Fails before anything is selected or scanned, so "the backend you
        # asked for is not there" is never mistaken for a verdict about
        # anyone's annotations.
        #
        # @raise [ValidatorError]
        def verify!
          raise ValidatorError, "#{describe} does not exist#{path_hint}" unless File.exist?(@path)
          raise ValidatorError, "#{describe} is not a file" unless File.file?(@path)
          raise ValidatorError, "#{describe} is not executable" unless File.executable?(@path)

          self
        end

        # @param paths [Enumerable<String>] spec files, as the caller named them
        # @return [Array<Linter::Result>] in argument order
        # @raise [ValidatorError] on any failure to obtain a report
        def check(paths)
          paths = paths.to_a
          # `validate-intent --source` with no argument is a usage error (exit
          # 2) — and there is nothing to ask it. `CLI#report_selection` has
          # already warned about the empty selection.
          return [] if paths.empty?

          batch(paths).flat_map { |group| check_batch(group) }
        end

        private

        def describe
          "the validator backend at #{@path} (#{ENV_VAR})"
        end

        # A bare command name is refused rather than resolved against PATH, and
        # the refusal says how to fix it. Which binary a CI job validated
        # against should not depend on what else happens to be installed and in
        # what order — and the failure that arrangement produces is a run that
        # succeeded against a different validator, which nothing downstream can
        # detect. One shell substitution buys a value that means one thing.
        def path_hint
          return "" if @path.include?(File::SEPARATOR)

          " — #{ENV_VAR} takes a path, not a command name; try #{ENV_VAR}=\"$(command -v #{@path})\""
        end

        # Greedy, order-preserving, and never empty: a single path longer than
        # the byte budget still gets its own batch rather than being dropped.
        # Dropping it would be the silent-omission failure this project keeps
        # naming — a file that was never checked, reported as clean.
        def batch(paths)
          groups = [[]]
          bytes = 0

          paths.each do |path|
            size = ValidatorBackend.escape_glob(path).bytesize + 1
            if !groups.last.empty? && (bytes + size > MAX_ARG_BYTES || groups.last.length >= MAX_BATCH_FILES)
              groups << []
              bytes = 0
            end
            groups.last << path
            bytes += size
          end

          groups
        end

        def check_batch(paths)
          # The pattern list keeps DUPLICATES. `specguard-lint a a` reports
          # every annotation twice — the Ruby path checks the files it is
          # handed, in the order it is handed them, without de-duplicating —
          # and so does the port. Deriving the argument vector from the
          # lookup hash below instead would silently collapse them and halve
          # the report.
          patterns = paths.map { |path| ValidatorBackend.escape_glob(path) }
          # escaped pattern -> the path the caller named. Used to undo
          # {escape_glob} on a `no-match`, whose `file` is the pattern rather
          # than a path that exists. Collapsing duplicates here is harmless:
          # the same pattern always maps back to the same path.
          originals = patterns.zip(paths).to_h

          document = run(patterns)
          findings = fetch_findings(document)
          check_annotation_count(document, findings)

          findings.map { |finding| result_for(finding, originals) }
        end

        # @return [Hash] the parsed report document
        def run(patterns)
          # No shell: the argument vector goes straight to execve, so a path
          # containing a space or a quote needs no quoting and cannot be
          # re-split. (`--json` is position-independent in the port; it is
          # written next to `--source` for readability.)
          stdout, stderr, status = Open3.capture3(@path, "--source", "--json", *patterns)

          check_status(status, stderr)
          parse_document(stdout, stderr)
        rescue SystemCallError => e
          # ENOENT/EACCES between #verify! and here (a binary deleted or
          # chmod'ed mid-run), ENOEXEC for a file that is not a program, E2BIG
          # if the batching above is ever outgrown.
          raise ValidatorError, "#{describe} could not be executed: #{e.message}"
        end

        # The port's own contract: 0 when everything checked was valid, 1 when
        # something was not. Anything else — 2 for a schema it could not load
        # or a mode it refuses, or death by signal — means it produced no
        # verdict, and neither may this run.
        def check_status(status, stderr)
          return if [0, 1].include?(status.exitstatus)

          raise ValidatorError, "#{describe} #{exit_description(status)}#{trailing(stderr)}"
        end

        def exit_description(status)
          return "exited #{status.exitstatus}" if status.exitstatus

          "did not exit normally (#{status})"
        end

        def parse_document(stdout, stderr)
          document = JSON.parse(stdout)
          unless document.is_a?(Hash)
            raise ValidatorError, "#{describe} emitted a #{document.class} where a JSON object was expected"
          end

          # `--source` is the only mode this asks for and the only one the port
          # implements `--json` for. A document announcing anything else means
          # the argument vector above no longer says what this code thinks it
          # says.
          mode = document["mode"]
          raise ValidatorError, "#{describe} reported mode #{mode.inspect}, expected \"source\"" unless mode == "source"

          document
        rescue JSON::ParserError => e
          raise ValidatorError,
                "#{describe} did not emit a JSON document: #{e.message}#{trailing(stderr)}"
        end

        def fetch_findings(document)
          findings = document["findings"]
          raise ValidatorError, "#{describe} emitted no `findings` array" unless findings.is_a?(Array)
          unless findings.all?(Hash)
            raise ValidatorError, "#{describe} emitted a `findings` entry that is not a JSON object"
          end

          findings
        end

        # The port counts ANNOTATION SITES EXAMINED in `summary.annotations`,
        # and a read failure or a no-match contributes none. So the count and
        # the findings are two independent statements about the same run, and
        # comparing them is what catches output truncated by a full pipe or a
        # killed batch — a case that would otherwise show up as a *smaller*
        # clean report, which is precisely the shape nobody notices.
        def check_annotation_count(document, findings)
          declared = document.dig("summary", "annotations")
          unless declared.is_a?(Integer)
            raise ValidatorError, "#{describe} emitted no integer `summary.annotations`"
          end

          seen = findings.count { |finding| !NON_ANNOTATION_KINDS.include?(finding["kind"]) }
          return if seen == declared

          raise ValidatorError,
                "#{describe} reported #{declared} annotation(s) but emitted #{seen} annotation finding(s)"
        end

        def result_for(finding, originals)
          file = finding["file"]
          raise ValidatorError, "#{describe} emitted a finding with no `file`" unless file.is_a?(String)

          kind = finding["kind"]
          errors = finding_errors(finding, file)

          return passing_result(finding, file, kind, errors) if finding["ok"] == true

          failing_result(finding, file, kind, errors, originals)
        end

        def finding_errors(finding, file)
          errors = finding["errors"]
          unless errors.is_a?(Array) && errors.all?(String)
            raise ValidatorError, "#{describe} emitted a finding on #{file} whose `errors` is not a list of strings"
          end

          errors
        end

        def passing_result(finding, file, kind, errors)
          unless kind.nil? && errors.empty?
            raise ValidatorError,
                  "#{describe} emitted a passing finding on #{file} carrying kind #{kind.inspect} " \
                  "and #{errors.length} error(s)"
          end

          Linter::Result.new(file: file, line: line_of(finding, file))
        end

        def failing_result(finding, file, kind, errors, originals)
          mapped = KINDS[kind]
          # An unknown kind is a vocabulary the port grew and this file has not
          # been taught. Guessing would render it under whichever branch of
          # #report_failure it fell into by accident; refusing keeps the
          # divergence visible and costs one exit 2.
          raise ValidatorError, "#{describe} emitted the unknown kind #{kind.inspect} on #{file}" if mapped.nil?
          raise ValidatorError, "#{describe} emitted a failing finding on #{file} with no errors" if errors.empty?

          return schema_result(finding, file, errors) if kind == "schema"

          problem_result(finding, file, kind, errors, originals)
        end

        def schema_result(finding, file, errors)
          Linter::Result.new(file: file, line: line_of(finding, file),
                             kind: Finding::KIND_SCHEMA, reasons: errors)
        end

        def problem_result(finding, file, kind, errors, originals)
          unless errors.length == 1
            # See the module comment: joining these would collapse several
            # lines the tool meant to print into one em-dashed sentence.
            raise ValidatorError,
                  "#{describe} emitted #{errors.length} errors on a #{kind} finding for #{file}, " \
                  "where the report can render exactly one"
          end

          return no_match_result(file, originals) if kind == "no-match"

          Linter::Result.new(file: file, line: line_of(finding, file),
                             kind: KINDS.fetch(kind), problem: errors.first)
        end

        # A path that matched nothing. Reported against the path the caller
        # named — `originals` undoes {ValidatorBackend.escape_glob} — and in
        # the gem's own words, because Go's "no file(s) match <pattern>" is a
        # statement about a glob pattern this CLI does not have and would carry
        # the escaped spelling into the report.
        def no_match_result(pattern, originals)
          Linter::Result.new(file: originals.fetch(pattern, pattern), line: 0,
                             kind: Finding::KIND_READ,
                             problem: "could not read file: no file at this path")
        end

        # `line` is null exactly where the finding is not line-scoped, which is
        # the same rule `Linter::Result#location` applies from the other side —
        # it drops the line for KIND_READ. 0 is the sentinel `Scanner` already
        # uses for a finding that never reached a line.
        def line_of(finding, file)
          line = finding["line"]
          return 0 if line.nil?
          raise ValidatorError, "#{describe} emitted a non-integer `line` on #{file}" unless line.is_a?(Integer)

          line
        end

        # The binary's stderr, appended to a diagnostic when it said anything.
        # A `--json` run that failed to produce a document has usually
        # explained itself there ("error: could not load schema …"), and
        # dropping it would leave the operator with "it did not emit a JSON
        # document" and nothing to act on.
        def trailing(stderr)
          text = stderr.to_s.strip
          return "" if text.empty?

          " — it said: #{text.lines.first.strip}"
        end
      end
    end
  end
end
