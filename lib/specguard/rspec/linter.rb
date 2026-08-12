# frozen_string_literal: true

module SpecGuard
  module RSpec
    # Applies the schema to the {Finding}s discovery produced, and says which
    # ones the run must fail on.
    #
    # This is the join between the two halves of the linter: discovery decides
    # *what* an annotation is, the schema decides whether it is *valid*, and
    # {Result} is the single shape the reporter and the exit code are both
    # derived from — so "what was printed" and "what we exited with" cannot
    # drift apart.
    #
    # == What counts as a failure
    #
    # Three things reach the same verdict from different directions:
    #
    #   * the payload could not be captured off the line at all
    #     (`Finding::KIND_EXTRACTION`) — a typo'd annotation;
    #   * it was captured but is not JSON even after normalization
    #     (`Finding::KIND_PARSE`);
    #   * it parsed but violates the schema.
    #
    # All three are "an annotation is malformed", which the contract fixes at
    # exit 1. A **missing** annotation is not among them — "lint, don't
    # require" (SPGD-12 §1): a file with no `@intent:` at all is clean.
    #
    # == The one case that is arguably not an annotation problem
    #
    # `Finding::KIND_READ` — a spec file that could not be opened or is not
    # valid UTF-8 — is also reported as a failure, and therefore also exits 1.
    # That is a deliberate choice, not an oversight: `validate-intent`
    # classifies it separately (its own `read` kind) and still reports it as
    # `FAIL` with exit 1.
    #
    # The CLASSIFICATION and the EXIT CODE are what match, and both are asserted
    # rather than described, in spec/specguard/rspec/validator_backend_spec.rb —
    # which runs this linter and the binary's recorded report over the same
    # inputs and compares them.
    #
    # The MESSAGE TEXT does not match on two of the read-failure shapes, and an
    # earlier version of this comment claimed it did — it quoted a
    # `FAIL bad_spec.rb — could not read file: ...` line as if the two tools
    # emitted the same bytes. They do not:
    #
    #   * a file that is not valid UTF-8 — the binary says `input is not
    #     well-formed UTF-8 (PROTOCOL.md §1.1 requires it)`;
    #     `Scanner.scan_text` says `invalid UTF-8 byte sequence`. Both name the
    #     condition rather than an offset, and both refuse the file, which is
    #     what PROTOCOL.md §1.1 requires; neither wording is specified.
    #   * a file that does not exist — the binary reports it on *stderr* as
    #     `error: no file(s) match '<path>'` (its arguments are glob patterns);
    #     `Scanner.scan_file` reports it on stdout as a read failure of that
    #     path (its arguments are paths).
    #
    # The line the contract actually draws is *the linter is broken* (2) versus
    # *the input it was pointed at is bad* (1). An unopenable file named on the
    # command line is the second. The kind is carried through rather than
    # flattened into prose so this stays a visible decision that a later ticket
    # can reverse in one place.
    class Linter
      # One annotation's verdict. `problem` is set when discovery could not
      # produce an intent at all; `reasons` when the schema rejected one.
      # They are mutually exclusive by construction.
      Result = Data.define(:file, :line, :kind, :problem, :reasons) do
        def initialize(file:, line:, kind: nil, problem: nil, reasons: [])
          super
        end

        def ok?
          problem.nil? && reasons.empty?
        end

        def failed?
          !ok?
        end

        # A read failure is not line-scoped: nothing in the file was ever seen,
        # and slice 1's `line` is a 0 sentinel rather than a location. The
        # binary drops the line for exactly these findings (`JSONFinding` in
        # open-test-intent's cmd/validate-intent/report.go — "`line` is null
        # where a finding is not line-scoped, `kind` is null on a passing
        # finding"), and `:0` is not somewhere a reader can go: anything
        # parsing `file:line` — CI annotations, editor quickfix, review
        # comments — would point at a line that does not exist.
        #
        # This is what makes `kind` load-bearing rather than decorative.
        #
        # The rule is a predicate rather than an inline comparison because it
        # now has two renderers: {CLI#report_failure} prints `file` instead of
        # `file:0`, and {JSONReporter} emits `"line": null` for the same
        # findings. Spelling `kind == Finding::KIND_READ` in both would let one
        # of them keep emitting the sentinel after the rule changed here.
        def line_scoped?
          kind != Finding::KIND_READ
        end

        def location
          line_scoped? ? "#{file}:#{line}" : file
        end
      end

      def initialize(schema)
        @schema = schema
      end

      # @param findings [Enumerable<Finding>]
      # @return [Array<Result>] in the order the findings were discovered
      def check(findings)
        findings.map { |finding| check_one(finding) }
      end

      # @param finding [Finding]
      # @return [Result]
      def check_one(finding)
        unless finding.extracted?
          return Result.new(file: finding.file, line: finding.line,
                            kind: finding.kind, problem: finding.problem)
        end

        reasons = @schema.violations(finding.intent)
        Result.new(file: finding.file, line: finding.line, reasons: reasons,
                   kind: reasons.empty? ? nil : Finding::KIND_SCHEMA)
      end
    end
  end
end
