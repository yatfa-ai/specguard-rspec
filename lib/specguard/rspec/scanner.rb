# frozen_string_literal: true

require "json"

module SpecGuard
  module RSpec
    # Runs the discovery pipeline over source files and returns {Finding}s.
    #
    # Pipeline, per `@intent:` token:
    #
    #   {AnnotationScanner} -> {PayloadNormalizer} -> `JSON.parse`
    #
    # This is the whole of the *input* half of the linter. It deliberately stops
    # at "an annotation is a Hash": nothing here loads or applies the
    # OpenTestIntent schema, so a Finding with an `intent` is merely
    # syntactically sound, not valid.
    module Scanner
      module_function

      # @param paths [Enumerable<String>]
      # @return [Array<Finding>] in file-then-line order
      def scan_files(paths)
        paths.flat_map { |path| scan_file(path) }
      end

      # @param path [String]
      # @return [Array<Finding>] one per `@intent:` token; empty when the file
      #   carries none. A file that cannot be read yields a single Finding at
      #   line 0 rather than raising — one bad file must not abort the run.
      #
      #   RATIFIED DIFFERENCE from the reference tool, for a path that does not
      #   exist. `bin/validate-intent` expands its arguments as glob PATTERNS
      #   (`bin/validate-intent:493`), so a name matching nothing is a
      #   statement about the pattern — `error: no file(s) match '<path>'`, on
      #   stderr, before any file is opened. This linter does no globbing:
      #   explicit files are checked as given and `--changed` derives its list
      #   from git, so every argument here is a PATH, and an unopenable one is
      #   a read failure OF THAT PATH — reported on stdout with the errno the
      #   reference cannot name. Adopting the reference's wording would mean
      #   giving this gem a globber first and changing what
      #   `specguard-lint 'foo*_spec.rb'` means for everyone already using it.
      #
      #   Both tools exit 1 and both name the file; that much is asserted, in
      #   open-test-intent's `tests/parity/run_ruby_parity.sh` under "ratified
      #   difference (b)", along with the case that matters more — a missing
      #   file does not stop either tool checking the good files named beside
      #   it.
      def scan_file(path)
        begin
          text = File.read(path, encoding: "UTF-8")
        rescue SystemCallError, IOError => e
          return [Finding.new(file: path, line: 0, problem: "could not read file: #{e.message}",
                              kind: Finding::KIND_READ)]
        end

        scan_text(text, file: path)
      end

      # @param text [String] source of one file
      # @param file [String] the path to record on each Finding
      # @return [Array<Finding>]
      def scan_text(text, file:)
        # An invalid byte sequence would make every String operation below raise
        # from deep inside the scanner. Report it as this file's one problem.
        #
        # RATIFIED DIFFERENCE from the reference tool, in the REASON TEXT only.
        # `bin/validate-intent` lets CPython describe the failure and the Go
        # port reproduces that description deliberately
        # (`cmd/validate-intent/fileio.go:69`), so both say `'utf-8' codec
        # can't decode byte 0xe9 in position 117: invalid continuation byte`
        # where this says `invalid UTF-8 byte sequence`. Reproducing it would
        # mean porting CPython's decoder-error classification into a gem whose
        # whole reason for vendoring the schema is to owe open-test-intent
        # nothing at runtime — and open-test-intent's own harness already
        # declines to compare that tail between Python and Go (run_parity.sh,
        # excluded group 1, "Non-UTF-8 input — the PROSE only").
        #
        # What is shared is asserted in `tests/parity/run_ruby_parity.sh` under
        # "ratified difference (a)": same classification, same file, same
        # `FAIL <file> — could not read file: ` prefix, a non-empty reason on
        # both sides, and exit 1.
        unless text.valid_encoding?
          return [Finding.new(file: file, line: 0, problem: "could not read file: invalid UTF-8 byte sequence",
                              kind: Finding::KIND_READ)]
        end

        AnnotationScanner.each_intent(text).map do |line_no, raw, problem|
          if problem
            Finding.new(file: file, line: line_no, problem: problem, kind: Finding::KIND_EXTRACTION)
          else
            parse(raw, file: file, line: line_no)
          end
        end
      end

      # RATIFIED DIFFERENCE from the reference tool. Two of them, and only the
      # first is a difference in reason TEXT — an earlier revision of this
      # comment claimed there was just the one, and it was wrong in a way worth
      # recording, because the mistake was structural rather than careless: it
      # described a symptom instead of a cause.
      #
      # == (1) The wording, when both parsers reject the payload
      #
      # `PayloadNormalizer` rescues PROTOCOL.md §1's permissive syntax on both
      # sides, so a payload it can fix renders identically. What reaches
      # `JSON.parse` still broken — a bare-word VALUE, a key that is not a key
      # — is described by whichever JSON parser is doing the parsing: this
      # interpolates Ruby's `JSON::ParserError#message`, while
      # `bin/validate-intent` lets CPython describe it and the Go port
      # reproduces CPython's wording deliberately (`cmd/validate-intent/
      # pyjson.go`). So `{bad_key}` is `expected object key, got 'bad_key}' at
      # line 1 column 2` here and `Expecting property name enclosed in double
      # quotes: line 1 column 2 (char 1)` there.
      #
      # Reproducing that tail would mean porting CPython's JSON diagnostics
      # into a gem whose entire reason for vendoring the schema is to owe
      # open-test-intent nothing at runtime — the argument `scan_text` makes
      # about CPython's DECODER classification, applied verbatim to its PARSER.
      #
      # What is shared is asserted in `tests/parity/run_ruby_parity.sh` under
      # "ratified difference (c)": same classification, same file, same LINE
      # (unlike a read failure, this one is line-scoped and both agree on the
      # line and even the column), same `could not parse annotation: ` prefix,
      # same counts, and exit 1. Only the tail is unpinned.
      #
      # == (2) THE ACCEPTANCE SET: the payloads only ONE parser rejects
      #
      # (1) is about how the two spell the same refusal. This is about the
      # payloads where they do not both refuse — a bigger difference, and the
      # generator (1) was hiding. CPython's grammar is strictly the more
      # permissive of the two, so there is a set of payloads `json.loads`
      # accepts and `JSON.parse` does not, and every member of it diverges.
      #
      # The set was DERIVED rather than guessed, because guessing is what
      # produced the "only the tail differs" claim: 89,108 documents — the
      # port's own `pyjson_fuzz_test.go` seed corpus and token alphabet, a
      # generated well-formed corpus, and every one of the 65,536 single
      # `\uXXXX` escapes — through both parsers. Widening the sweep did not add
      # a member. It has exactly THREE:
      #
      #   1. the non-finite literals `NaN` / `Infinity` / `-Infinity`. CPython
      #      accepts them and the port accepts them ON PURPOSE — pyjson.go's
      #      "WHAT IT BUYS BEYOND THE PROSE" records that an earlier Go
      #      decoder rejecting them "made Go classify such a document as a
      #      parse failure where Python reported a schema violation", and that
      #      retiring that exclusion was the point of the file. The same
      #      divergence it closed between Go and Python is the one that reopens
      #      here between Ruby and Go.
      #   2. a HIGH surrogate escape (`\ud800`-`\udbff`) not followed by a LOW
      #      one. Ruby raises `incomplete surrogate pair`, or `invalid
      #      surrogate pair` when the next escape is not a low surrogate. A
      #      lone LOW surrogate is accepted by both — the rule is narrower than
      #      "surrogate escapes diverge".
      #   3. container nesting past Ruby's `max_nesting: 100` default. CPython
      #      has no document-depth limit short of its recursion limit.
      #
      # Each produces one of two shapes, depending on whether the payload the
      # port successfully parses then passes the schema:
      #
      #   (v)  NOT schema-valid — the CLASSIFICATION differs. This path reports
      #        KIND_PARSE and renders one em-dash line; the backend reports
      #        KIND_SCHEMA and renders a `-> ` line per violation. File, line,
      #        counts and exit code still agree.
      #   (vi) schema-valid — the VERDICT differs. This path reports the
      #        annotation malformed and exits 1; the backend reports nothing
      #        and exits 0. Only the file agrees.
      #
      # (vi) is reachable through member 2 alone, and provably so: a
      # schema-valid payload must put the offending syntax in a value the
      # schema permits, and every such value is a string or an array of strings
      # (`SpecGuard::RSpec::SCHEMA_PATH`). A number and a container cannot
      # occupy a string slot; a surrogate escape lives inside one.
      #
      # RATIFIED, and the reason is scope, not preference. `allow_nan: true`
      # would close member 1 and `max_nesting: false` would close member 3 —
      # both are options on the `JSON.parse` call below — but member 2 has no
      # option and would need CPython's string decoder ported into this gem,
      # which is the trade `scan_text` and (1) above have each already
      # declined. Closing two of three would leave the set inconsistent, and
      # every one of the three is a change to the DEFAULT path, which the slice
      # that introduced `ValidatorBackend` explicitly holds fixed. Whether the
      # gem should adopt CPython's acceptance grammar wholesale is a question
      # about this gem's default behaviour, and it is deliberately left open
      # rather than settled here.
      #
      # Asserted from both sides — the enumeration itself, the boundary, and
      # both shapes — in `spec/specguard/rspec/validator_backend_spec.rb` under
      # "the JSON acceptance-set difference", and against the real binary in
      # `tests/parity/run_ruby_parity.sh` under "ratified difference (d)" and
      # section 8b's entries (v) and (vi).
      #
      # Note that `JSON::NestingError` is a subclass of `JSON::ParserError`, so
      # member 3 is already carried by the rescue below; it needs no clause of
      # its own, and adding one would suggest the classification differs when
      # it does not.
      #
      # @return [Finding]
      def parse(raw, file:, line:)
        intent = JSON.parse(PayloadNormalizer.normalize(raw))

        # A bare `[...]` or scalar is syntactically fine JSON but is not an
        # annotation. Reject it here so downstream stages can assume a Hash.
        unless intent.is_a?(Hash)
          return Finding.new(file: file, line: line, kind: Finding::KIND_PARSE,
                             problem: "annotation payload is not an object")
        end

        Finding.new(file: file, line: line, intent: intent)
      rescue ScanError, JSON::ParserError => e
        Finding.new(file: file, line: line, kind: Finding::KIND_PARSE,
                    problem: "could not parse annotation: #{e.message}")
      end
    end
  end
end
