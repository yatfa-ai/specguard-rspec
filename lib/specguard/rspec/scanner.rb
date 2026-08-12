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
      #   RATIFIED DIFFERENCE from the binary, for a path that does not exist.
      #   `validate-intent` expands its arguments as glob PATTERNS, so a name
      #   matching nothing is a statement about the pattern —
      #   `error: no file(s) match "<path>"`, on stderr, before any file is
      #   opened. This linter does no globbing: explicit files are checked as
      #   given and `--changed` derives its list from git, so every argument
      #   here is a PATH, and an unopenable one is a read failure OF THAT PATH —
      #   reported on stdout with the errno the binary never had occasion to
      #   name. Adopting the binary's wording would mean giving this gem a
      #   globber first, and changing what `specguard-lint 'foo*_spec.rb'` means
      #   for everyone already using it.
      #
      #   Both tools exit 1 and both name the file; that much is asserted in
      #   spec/specguard/rspec/validator_backend_spec.rb, along with the case
      #   that matters more — a missing file does not stop either tool checking
      #   the good files named beside it.
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
        # RATIFIED DIFFERENCE from the binary, in the REASON TEXT only. Both
        # refuse the file — PROTOCOL.md §1.1 makes UTF-8 part of what a JSON
        # text IS, and neither side repairs the bytes — but they word it
        # differently: the binary names the offending position, this names the
        # condition. Neither wording is specified, so neither is wrong; what
        # matters is that both classify it as a READ failure and neither
        # substitutes U+FFFD and carries on.
        #
        # What is shared is asserted in spec/specguard/rspec/validator_backend_spec.rb:
        # same classification, same file, same `FAIL <file> — could not read
        # file: ` prefix, a non-empty reason on both sides, and exit 1.
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

      # RATIFIED DIFFERENCE from the binary. Two of them, and only the first is
      # a difference in reason TEXT.
      #
      # == (1) The wording, when both parsers reject the payload
      #
      # `PayloadNormalizer` rescues PROTOCOL.md §1's permissive syntax on both
      # sides, so a payload it can fix renders identically. What reaches
      # `JSON.parse` still broken — a bare-word VALUE, a key that is not a key
      # — is described by whichever JSON parser is doing the parsing: this
      # interpolates Ruby's `JSON::ParserError#message`, while the binary uses
      # its own. So `{bad_key}` is `expected object key, got 'bad_key}' at line
      # 1 column 2` here and `expected a double-quoted property name (line 1,
      # column 2)` there.
      #
      # Reproducing that tail would mean carrying a second parser's diagnostics
      # in a gem whose entire reason for vendoring the schema is to owe
      # open-test-intent nothing at runtime — the argument `scan_text` makes
      # about the DECODER, applied verbatim to the PARSER. PROTOCOL.md
      # specifies the accepted LANGUAGE, not the prose a validator refuses in,
      # so two spellings of one refusal are both conformant.
      #
      # What is shared is asserted in
      # spec/specguard/rspec/validator_backend_spec.rb: same classification,
      # same file, same LINE (unlike a read failure, this one is line-scoped and
      # both agree on the line and even the column), same
      # `could not parse annotation: ` prefix, same counts, and exit 1. Only the
      # tail is unpinned.
      #
      # == (2) THE ACCEPTANCE SET: where the two parsers take different input
      #
      # (1) is about how the two spell the same refusal. This is about payloads
      # where they do not both refuse — a bigger difference, and the generator
      # (1) was hiding.
      #
      # This USED to be a three-member set in which the binary was the
      # permissive side, because its parser reproduced a foreign runtime's
      # grammar that `PROTOCOL.md` had never specified. PROTOCOL.md §1.1 states
      # the grammar now: an RFC 8259 JSON text, with the three points that RFC
      # leaves open settled explicitly. The binary refuses the non-finite
      # literals (§1.1(b)), unpaired surrogate escapes (§1.1(a)) and nesting
      # past 100 (§1.1(c)), and `JSON.parse` refuses or limits all three too, so
      # those three have CONVERGED.
      #
      # WHAT SURVIVES RUNS THE OTHER WAY: this parser is now the permissive one.
      #
      #   * A LONE LOW surrogate escape (`\udc00`-`\udfff`). `JSON.parse`
      #     accepts it; §1.1(a) refuses it, because a surrogate escape must form
      #     a pair. Ruby refuses only the HIGH half, which is why the rule here
      #     is narrower than "surrogate escapes diverge".
      #   * The nesting BOUNDARY, which sits a little deeper here than
      #     §1.1(c)'s 100.
      #
      # The surrogate one is not merely a verdict difference. What `JSON.parse`
      # returns for `"\udc00"` is a String whose `valid_encoding?` is FALSE: it
      # cannot be re-serialised and cannot cross the ingest transport, so a
      # payload this parser calls valid is one the gem cannot send. That is the
      # cost §1.1(a) exists to remove, and it is still paid on this path.
      #
      # It produces two shapes, depending on whether the payload this parser
      # accepts then passes the schema:
      #
      #   (v)  NOT schema-valid — the CLASSIFICATION would differ. Unreachable
      #        today: a schema-valid payload has to put the offending syntax in
      #        a value the schema permits, and every such value is a string or
      #        an array of strings (`SpecGuard::RSpec::SCHEMA_PATH`) — so the
      #        surviving member always lands in a string, and always in (vi).
      #   (vi) schema-valid — the VERDICT differs. This path reports nothing and
      #        exits 0; the backend reports a parse failure and exits 1.
      #
      # RATIFIED, and the reason is scope rather than preference. This gem's
      # hand-rolled validation logic is slated for REMOVAL by the roadmap that
      # owns the binary, not for repair; and closing the gap here would be a
      # change to the DEFAULT path, which the slice that introduced
      # `ValidatorBackend` explicitly holds fixed. Whoever removes this parser
      # closes it by deletion.
      #
      # Asserted from both sides — what this parser accepts, the convergence,
      # and the surviving divergence — in
      # `spec/specguard/rspec/validator_backend_spec.rb` under "the JSON
      # acceptance set".
      #
      # Note that `JSON::NestingError` is a subclass of `JSON::ParserError`, so
      # a nesting refusal is already carried by the rescue below; it needs no
      # clause of its own, and adding one would suggest the classification
      # differs when it does not.
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
