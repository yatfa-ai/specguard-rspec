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
