# frozen_string_literal: true

module SpecGuard
  module RSpec
    # One `@intent:` annotation, located and (where possible) parsed.
    #
    # Exactly one of `intent` and `problem` is non-nil:
    #
    #   * `intent`  — the parsed annotation as a Hash with String keys. Says
    #     nothing about whether it is *valid*; schema validation is a later
    #     stage, so a Finding with an `intent` may still be rejected then.
    #   * `problem` — why this annotation could not be turned into a Hash at
    #     all, as a human-readable sentence.
    #
    # `kind` names *how* it failed and is nil when it did not. It is carried
    # here rather than reconstructed by the caller because a failed extraction
    # and an unparseable payload both land in `problem`, which makes the two
    # indistinguishable downstream once flattened to prose.
    #
    # NOTE: this is a subclass of an anonymous `Data.define` rather than a
    # `Data.define do ... end` block, because a constant assigned inside that
    # block binds to the *lexically* enclosing module (SpecGuard::RSpec) rather
    # than to the value class — so KIND_EXTRACTION below would silently not be
    # `Finding::KIND_EXTRACTION`.
    class Finding < Data.define(:file, :line, :intent, :problem, :kind)
      # The annotation's payload could not be captured off the line at all
      # (unterminated literal, or no `{...}` after the token).
      KIND_EXTRACTION = :extraction

      # The payload was captured but is not JSON even after normalization.
      KIND_PARSE = :parse

      # The file itself could not be read (missing, unopenable, or not valid
      # UTF-8), so no annotation in it was ever seen. Distinct from
      # {KIND_EXTRACTION} — nothing here is a claim about an annotation — and
      # named after the `read` kind the validator's `--json` report carries, so
      # the two classifications line up.
      KIND_READ = :read

      # The payload parsed but violates the OpenTestIntent schema. Not produced
      # by discovery — {Linter} stamps it — but it lives here so the full set
      # of ways an annotation can fail is written down in one place.
      KIND_SCHEMA = :schema

      def initialize(file:, line:, intent: nil, problem: nil, kind: nil)
        super
      end

      # True when the annotation yielded a Hash. Not a claim that it is *valid*.
      def extracted?
        problem.nil?
      end

      def problem?
        !problem.nil?
      end

      def location
        "#{file}:#{line}"
      end
    end
  end
end
