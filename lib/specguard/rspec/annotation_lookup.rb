# frozen_string_literal: true

# Answers one question, for one example at a time: *is this test annotated, and
# with what?*
#
# It is the formatter's half of the annotation story. The linter's half already
# exists and is not duplicated here — {SpecGuard::RSpec::Scanner} finds every
# `@intent:` in a file, captures its payload string-aware and parses it, and
# {SpecGuard::RSpec::Schema} decides whether the result is valid. This class
# consumes both. Writing a second extractor would guarantee that the tool
# telling an author their annotation is wrong and the tool reporting it to the
# platform eventually disagree about what an annotation *is*.
#
# Requiring the linter's chain from here is safe in the direction that matters:
# `lib/specguard/rspec.rb` does not require `rspec/core`, so pulling it in from
# the formatter's side keeps `bin/specguard-lint` loadable on a machine with no
# RSpec installed. spec/specguard/rspec/formatter_loading_spec.rb pins that in
# both directions.
require_relative "../rspec"

module SpecGuard
  module RSpec
    # == The lookback rule (SPGD-12 §2)
    #
    # `example.metadata[:line_number]` is the line the `it` is on. An annotation
    # counts as this example's when it sits on that line (the trailing form) or
    # on the line immediately above it (the preceding-comment form):
    #
    #   # @intent: { entity: "Order", ... }    <- line above
    #   it "restores stock on refund" do       <- metadata[:line_number]
    #
    #   it "surfaces the decline reason" do # @intent: { ... }   <- same line
    #
    # One line of lookback, no more. Multi-line annotations are unsupported in
    # v1 (PROTOCOL.md §1 requires an annotation to fit on one line), so a wider
    # window could only ever attach an annotation to the wrong example.
    #
    # == Only the comment form is inherited by the line below
    #
    # The two forms are not symmetric, and the difference is not cosmetic. A
    # comment-only line hosts no example, so an annotation written there has
    # exactly one possible claimant — the line under it. An annotation written
    # in the trailing form is on a line that *is* an example's, so it has two,
    # and one-liner specs make the second one ordinary rather than exotic:
    #
    #   it { is_expected.to eq(1) } # @intent: { entity: "Order", ... }
    #   it { is_expected.to be_positive }
    #
    # Lookback that did not distinguish the forms would report **both** of those
    # as annotated, carrying the same intent — so the platform would store the
    # second example's declared purpose as something nobody declared, and count
    # it in `annotated_specs_count`. That is worse than reporting it
    # unannotated: a missing annotation is a visible gap, an invented one is
    # confident false telemetry, and it inflates the very ratio `status` exists
    # to keep honest.
    #
    # So a Finding is claimable by the line below it only when its own line is
    # comment-only ({COMMENT_LINE}). Deciding that needs the source line, which
    # is why {#build_index} reads the file itself and calls {Scanner.scan_text}
    # rather than {Scanner.scan_file} — the read is the same single read either
    # way, and the alternative was a second one per file purely to re-derive
    # what the first one already had in hand.
    #
    # == Why a malformed annotation is reported as *unannotated*
    #
    # {AnnotationScanner} states, correctly, that a typo'd annotation "must fail
    # loudly rather than silently counting as unannotated". That is the
    # **linter's** stance, and the linter already acts on it: it prints the
    # file:line and exits 1. It cannot bind the formatter, which is under the
    # never-block-CI contract and has no way to be loud that is not also a way
    # to be in someone's build output.
    #
    # The alternative is worse than it looks. `Ingest::Payload` is
    # all-or-nothing — it collects errors globally and `valid?` requires the
    # list to be empty — so shipping one schema-invalid intent does not lose
    # that annotation, it loses **the whole run**: a 400, and no telemetry for
    # any of the other twenty thousand examples. Downgrading one annotation to
    # `unannotated` costs one row's metadata. The example's name, duration and
    # outcome still ship either way.
    #
    # So every one of these produces the same answer — `nil`, meaning
    # unannotated:
    #
    #   * no `@intent:` on either candidate line;
    #   * an `@intent:` on the line above that is *not* a comment-only line —
    #     the trailing form belongs to its own example and lends itself to
    #     nobody;
    #   * an `@intent:` whose payload could not be captured or parsed
    #     ({Finding#problem?} — `KIND_EXTRACTION` / `KIND_PARSE`);
    #   * a file that could not be read at all (`KIND_READ`);
    #   * a syntactically fine annotation the schema rejects;
    #   * the schema itself failing to load.
    #
    # == Cost
    #
    # {AnnotationScanner.each_intent} walks every line of the file it is handed.
    # Scanning per *example* would make a 20,000-example suite read and walk its
    # spec files 20,000 times, on the critical path of somebody's test run. So
    # each file is read and scanned at most once and reduced to an {Index}:
    # O(files), not O(examples). Schema validation is memoized on the same
    # principle — per distinct annotation, not per example carrying it.
    class AnnotationLookup
      # Findings at line 0 are {Finding::KIND_READ} — "this file was never
      # read", not "there is an annotation on line 0". Keeping the sentinel out
      # of the index is what makes {Index#finding_for}'s unconditional
      # `line - 1` lookback safe for an example on line 1.
      FIRST_REAL_LINE = 1

      # A line whose only content is a comment: the preceding-comment form, and
      # the only form an example on the next line may claim. Leading whitespace
      # is allowed because annotations are indented with the examples they
      # describe.
      COMMENT_LINE = /\A\s*#/

      # One file's annotations, split by who is allowed to claim them.
      #
      #   own          every annotation, by the line it was written on
      #   inheritable  only those in the comment form, by that same line
      #
      # A line's own annotation always wins: the trailing form is written *on*
      # the example, so when a file somehow carries both it is the more specific
      # of the two, and a malformed trailing annotation is not quietly
      # backfilled from the comment above it — that would attach an intent its
      # author had already stopped meaning.
      #
      # `line - 1` is 0 for an example on line 1, and {AnnotationLookup#build_index}
      # is what guarantees that reads back as "no annotation": line 0 is never a
      # key, because the only Finding produced there is the KIND_READ sentinel.
      Index = Struct.new(:own, :inheritable) do
        # @return [Finding, nil]
        def finding_for(line)
          own[line] || inheritable[line - 1]
        end
      end

      # The answer for a file nothing could be read out of. Its own constant so
      # the pessimistic pre-scan cache in {#index_for} and the unreadable-file
      # path cannot drift apart.
      EMPTY_INDEX = Index.new({}.freeze, {}.freeze).freeze

      # @param schema_path [String] the vendored OpenTestIntent schema. Injected
      #   so a spec can point at a broken one without stubbing the loader.
      def initialize(schema_path: SCHEMA_PATH)
        @schema_path = schema_path
        @indexes = {}
        @verdicts = {}
      end

      # The intent to attach to one example, or nil when it is unannotated.
      #
      # Nothing here is rescued: a caller that cannot survive an exception must
      # say so itself, and the formatter does — it wraps this in the same
      # `never_fail_the_run` envelope as everything else, so a blow-up costs the
      # example its annotation and not the suite its exit code. The memoization
      # below is deliberately written so that a failure is cached too, which is
      # what keeps "warns once" from becoming "warns once but rescans the file
      # for every one of the remaining examples".
      #
      # @param file [String, nil] the example's file, as the payload records it
      # @param line [Integer, nil] `example.metadata[:line_number]`
      # @return [Hash, nil] the parsed, schema-valid annotation
      def intent_for(file:, line:)
        finding = finding_for(file: file, line: line)

        # {Finding#extracted?} is the discovery layer's own word for "this
        # yielded a Hash" — and, pointedly, "not a claim that it is valid".
        # Everything it excludes (KIND_EXTRACTION, KIND_PARSE, KIND_READ) is an
        # annotation the linter fails the build over and this half must not.
        return nil unless finding&.extracted?

        validated(finding.intent)
      end

      private

      def finding_for(file:, line:)
        return nil unless file.is_a?(String) && !file.empty?
        return nil unless line.is_a?(Integer) && line >= FIRST_REAL_LINE

        index_for(file).finding_for(line)
      end

      # @return [Index]
      def index_for(file)
        return @indexes[file] if @indexes.key?(file)

        # Cache the pessimistic answer *before* the scan, not after. If the scan
        # raises, the raise still reaches the formatter (which warns once and
        # moves on) but the empty index stays behind, so the next example in the
        # same file is answered from the cache instead of re-raising and
        # re-reading. Without this, "warns once" would still mean "re-reads a
        # broken file once per example" — the O(examples) cost this class exists
        # to remove, reappearing on exactly the unhappy path where somebody's CI
        # is already having a bad day.
        @indexes[file] = EMPTY_INDEX
        @indexes[file] = build_index(file)
      end

      # @return [Index]
      def build_index(file)
        text = read(file)
        return EMPTY_INDEX if text.nil?

        lines = nil
        own = {}
        inheritable = {}

        Scanner.scan_text(text, file: file).each do |finding|
          line = finding.line
          next unless line.is_a?(Integer) && line >= FIRST_REAL_LINE

          # First wins. `each_intent` resumes scanning after each captured
          # payload, so trailing prose containing a second `@intent:` yields a
          # second Finding on the same line. The annotation is the one the
          # author wrote first; the rest of the line is commentary. Stated here
          # rather than left to Hash-insertion order.
          next if own.key?(line)

          own[line] = finding
          # Materialized only once a real annotation has been found, and never
          # for a file `scan_text` refused: its invalid-UTF-8 answer is a single
          # line-0 Finding, filtered out above, and splitting such a string is
          # itself an ArgumentError waiting to happen.
          lines ||= text.lines
          inheritable[line] = finding if COMMENT_LINE.match?(lines[line - 1].to_s)
        end

        Index.new(own, inheritable)
      end

      # {Scanner.scan_file} would do this read, but it hands back only Findings
      # and the form of an annotation is a property of the *line* it sits on. So
      # the read happens here and {Scanner.scan_text} — the same pipeline, one
      # stage lower — does the extracting. Nothing about what an annotation *is*
      # is re-implemented; a second extractor is how the tool that tells an
      # author their annotation is wrong and the tool that reports it to the
      # platform end up disagreeing.
      #
      # The rescue mirrors `scan_file`'s own, and the two agree on the answer: it
      # turns an unreadable file into a line-0 KIND_READ Finding, which this
      # class filters out, and nil here becomes {EMPTY_INDEX}. Either way, every
      # example in a file that could not be read is unannotated.
      #
      # @return [String, nil]
      def read(file)
        File.read(file, encoding: "UTF-8")
      rescue SystemCallError, IOError
        nil
      end

      # Keyed by the intent itself, so an annotation repeated across a suite is
      # compiled against the schema once rather than once per example that
      # carries it. json_schemer is not free, and this class is explicitly about
      # not paying O(examples) for work that is O(annotations).
      #
      # @return [Hash, nil] the intent when the schema accepts it
      def validated(intent)
        return @verdicts[intent] if @verdicts.key?(intent)

        @verdicts[intent] = validate(intent)
      end

      def validate(intent)
        loaded = schema
        return nil if loaded.nil?

        loaded.violations(intent).empty? ? intent : nil
      end

      # Loaded on first use, and at most once — including when loading fails.
      #
      # {Schema.load} raises {SchemaError} when the vendored document cannot be
      # read, parsed or compiled. Under the linter that is a deliberate exit 2.
      # Here it must not be an exit anything, so the raise is left to the
      # formatter's envelope and the nil that gets cached in its place turns
      # every subsequent annotation into an honest `unannotated` — the same
      # answer this class gives for every other thing it could not verify.
      def schema
        return @schema if defined?(@schema)

        @schema = nil
        @schema = Schema.load(@schema_path)
      end
    end
  end
end
