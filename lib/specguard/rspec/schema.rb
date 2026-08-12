# frozen_string_literal: true

require "json"
require "json_schemer"

module SpecGuard
  module RSpec
    # The vendored OpenTestIntent schema could not be loaded.
    #
    # Deliberately *not* a {UsageError} even though both map to exit 2: this is
    # the linter being broken, not the caller misusing it, and the message
    # wording follows the validator's rather than the CLI's own. Keeping the
    # two distinct is what lets the CLI print
    # `error: could not load schema <path>: ...` — the shape `validate-intent`
    # uses — for one and `specguard-lint: error: ...` for the other.
    class SchemaError < Error; end

    # The OpenTestIntent v1 schema, loaded and applied.
    #
    # == Why loading failure is exit 2 and not exit 1
    #
    # The exit contract (SPGD-12 §1) spends `1` on "an annotation is
    # malformed". If a packaging accident leaves the vendored schema out of the
    # gem, the obvious Ruby implementation lets the exception escape and Ruby
    # exits 1 — so CI reports a malformed annotation and a developer goes
    # hunting for a bad annotation that does not exist. The validator already
    # ruled on this, and this gem follows it:
    #
    #     except (OSError, json.JSONDecodeError) as exc:
    #         print("error: could not load schema %s: %s" % (SCHEMA_PATH, exc), file=sys.stderr)
    #         return 2
    #     # open-test-intent, bin/validate-intent:858-862
    #
    # Hence {SchemaError}: every way loading can fail is caught here and
    # retyped, so the CLI can map the whole class of them to 2 without
    # inspecting exception classes from three different libraries.
    #
    # The CLI loads this **before** it scans anything, so a broken schema can
    # never produce a run that reports "0 malformed" having validated nothing.
    class Schema
      # @param path [String] the vendored schema
      # @return [Schema]
      # @raise [SchemaError] if it cannot be read, parsed, or compiled
      def self.load(path = SCHEMA_PATH)
        document = ::JSON.parse(File.read(path, encoding: "UTF-8"))
        new(document: document, path: path)
      rescue StandardError => e
        # Intentionally broad. Reading can raise SystemCallError/IOError,
        # parsing JSON::ParserError, and compiling or meta-validating whatever
        # json_schemer decides an unusable schema document deserves. All of
        # them mean the same thing to the caller, and all of them must be 2
        # rather than an uncaught exception's 1.
        raise SchemaError, "could not load schema #{path}: #{e.message}"
      end

      attr_reader :document, :path

      def initialize(document:, path: SCHEMA_PATH, renderer: ViolationRenderer.new)
        @document = document
        @path = path
        @renderer = renderer
        @schemer = JSONSchemer.schema(document)
        reject_unusable_schema!
      end

      # @param intent [Object] one parsed annotation
      # @return [Array<String>] reason lines in the validator's grammar and
      #   order; empty means the annotation is valid
      #
      # The **validator** decides the verdict; the renderer only decides the
      # wording. Deriving "is this annotation valid?" from "could we phrase a
      # sentence about it?" would make an unphrasable violation and a clean
      # annotation the same state — and under {Linter} that state is a green
      # run, which is this project's signature vacuous green (KB SPGD-78)
      # arriving through the one door the whole rendering strategy exists to
      # close. The gemspec pins `~> 2.5`, which admits 2.6 and beyond; the
      # renderer is built from structured fields precisely so a bump degrades
      # to *wrong-looking text* rather than to silence, and this is what keeps
      # that promise true for error shapes it has never seen.
      def violations(intent)
        errors = @schemer.validate(intent).to_a
        return [] if errors.empty?

        rendered = @renderer.render(errors, intent)
        rendered.empty? ? errors.map { |error| unrenderable_reason(error) } : rendered
      end

      private

      # Last resort: json_schemer's own sentence, and failing even that, the
      # error's structure. Both are worse output than the reference grammar.
      # Both are enormously better than reporting the annotation as clean.
      def unrenderable_reason(error)
        error["error"] || "does not match the schema at #{error['schema_pointer']}"
      end

      # Checks the vendored document against draft-07's own meta-schema before
      # anything is validated against it.
      #
      # This is not belt-and-braces, it closes a real hole. json_schemer is
      # permissive about nonsense in a *schema*: given `{"type": 42}` it
      # compiles happily and then treats the keyword as absent — so a schema
      # file corrupted in a way that still parses as JSON produces a linter
      # that **accepts every annotation** and reports a clean run. That is this
      # project's signature vacuous-green defect (KB SPGD-78) arriving through
      # the back door, and it is worse than a crash because it looks like
      # success.
      #
      # Some malformations are lazier still — `{"required": "nope"}` compiles,
      # passes nothing, and raises NoMethodError from inside the first
      # `#validate`. Meta-validating here converts that whole family into a
      # SchemaError at load time, which the CLI reports as
      # `error: could not load schema ...` and exits 2 on.
      def reject_unusable_schema!
        return if @schemer.valid_schema?

        raise Error, "not a valid draft-07 schema (#{@schemer.validate_schema.first&.fetch('error')})"
      end
    end
  end
end
