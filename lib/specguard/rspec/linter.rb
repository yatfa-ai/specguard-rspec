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
    # That is a deliberate parity choice, not an oversight: the reference tool
    # classifies it separately (its own `KIND_READ`, `bin/validate-intent:91`)
    # and still reports it as `FAIL` with exit 1.
    #
    # The CLASSIFICATION and the EXIT CODE are what match, and both are now
    # asserted rather than described: open-test-intent's
    # `tests/parity/run_ruby_parity.sh` runs this linter and the Go port over
    # the same inputs and compares them. Its sections named "ratified
    # difference (a)", "ratified difference (b)" and "an unreadable file" cover
    # the three read-failure shapes. (Cited by name, not by number — that file
    # renumbers, and a number nothing checks across two repositories is a
    # citation waiting to point somewhere else.)
    #
    # The MESSAGE TEXT does not match on two of those three, and an earlier
    # version of this comment claimed it did — it quoted a `FAIL bad_spec.rb —
    # could not read file: ...` line as if the two tools emitted the same
    # bytes. They do not, and the harness now says so out loud:
    #
    #   * a file that is not valid UTF-8 — the reference reproduces CPython's
    #     `'utf-8' codec can't decode byte 0xe9 in position 117: invalid
    #     continuation byte`; `Scanner.scan_text` emits a fixed string.
    #   * a file that does not exist — the reference reports it on *stderr* as
    #     `error: no file(s) match '<path>'` (its arguments are glob patterns);
    #     `Scanner.scan_file` reports it on stdout as a read failure of that
    #     path (its arguments are paths).
    #
    # Both differences are RATIFIED, with the reasoning written down in that
    # script's header and asserted there — including the assertion that they
    # still differ, so closing either one fails the harness and forces the
    # ratification to be retired rather than left to rot the way this comment
    # did.
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
      #
      # `intent` is WHAT THE PAYLOAD PARSED TO, carried alongside the verdict
      # rather than left for a second parser to re-derive. It is nil when there
      # was no payload (any `problem`), and — like the port's `intent` key — it
      # is populated even when `reasons` is not empty: a schema-rejected
      # annotation did parse, and `ok?` already reports the verdict.
      #
      # It is here rather than only in {Finding} because the BACKEND path never
      # produces a Finding. {ValidatorBackend::Runner} reconstructs Results
      # straight from the port's report, so a payload that stopped at Finding
      # would be available on the Ruby path and absent on the backend one —
      # which is the divergence this field exists to remove, re-created one
      # layer down.
      Result = Data.define(:file, :line, :kind, :problem, :reasons, :intent) do
        def initialize(file:, line:, kind: nil, problem: nil, reasons: [], intent: nil)
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
        # reference drops the line for exactly these findings
        # (`bin/validate-intent:521` — "when a finding is not line-scoped ...
        # kind is null"), and `:0` is not somewhere a reader can go: anything
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

        # The intent, but only when it is a value this gem can actually hand on
        # — nil otherwise.
        #
        # Parsing a payload is not the same as being able to REPRODUCE it, and
        # Ruby draws that line in a place CPython does not. `JSON.parse` accepts
        # a lone LOW surrogate (`"\udc00Or"`) and returns a String whose
        # `valid_encoding?` is false; `JSON.generate` then refuses the same
        # value with `source sequence is illegal/malformed utf-8`. Such a
        # payload clears discovery AND the schema — `Scanner` extracts it and
        # `violations` is empty — so nothing before this point has any reason to
        # stop it, and it detonates at the point of USE: in the formatter's
        # transport, or mid-document in {JSONReporter}, having already cost the
        # run its telemetry rather than costing one example its annotation.
        #
        # Answered here, once, because BOTH renderers need it and neither is the
        # natural owner. Nothing is substituted — a repaired payload is one the
        # author did not write, and shipping it is indistinguishable downstream
        # from shipping the right one (KB SPGD-78). Unshippable means
        # unannotated.
        def representable_intent
          intent unless unrepresentable?(intent)
        end

        private

        # Recurses because the bad value is a leaf: it arrives inside an
        # annotation's string VALUE (or key), never as the whole payload.
        def unrepresentable?(value)
          case value
          when String then !value.valid_encoding?
          when Array  then value.any? { |item| unrepresentable?(item) }
          when Hash   then value.any? { |k, v| unrepresentable?(k) || unrepresentable?(v) }
          else false
          end
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
                   kind: reasons.empty? ? nil : Finding::KIND_SCHEMA,
                   intent: finding.intent)
      end
    end
  end
end
