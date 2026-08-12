# frozen_string_literal: true

module SpecGuard
  module RSpec
    # Finds `@intent:` annotations in test source and captures the object
    # literal that follows each one.
    #
    # This is a *syntactic* pass only: it hands back the payload exactly as
    # written (still in PROTOCOL.md §1's permissive syntax — see
    # {PayloadNormalizer}) and never inspects its contents. Schema validation is
    # a later stage entirely.
    #
    # The scan is **string-aware**: quoted content is skipped over wholesale, so
    # a `behavior` sentence containing an apostrophe or an unbalanced `{` cannot
    # terminate the capture early. Plain brace-counting gets that case wrong.
    #
    # The algorithm is PROTOCOL.md §1's: find each `@intent:` token and capture
    # the object literal after it, string-aware and bracket-balanced.
    # open-test-intent's `validate-intent` implements the same rules; where the
    # two disagree, PROTOCOL.md decides.
    module AnnotationScanner
      INTENT_TOKEN = "@intent:"

      # Closing bracket => the opener it must match.
      OPENERS = { "}" => "{", "]" => "[" }.freeze

      # The `{` at `start` was never closed on this line.
      UNTERMINATED_OBJECT = "unterminated object literal (an annotation must fit on one line)"
      UNBALANCED_BRACKETS = "unbalanced brackets in the annotation payload"
      NO_PAYLOAD = "no '{...}' object literal follows the @intent: token"

      module_function

      # Yields `[line_no, raw_payload, problem]` for every `@intent:` token in
      # `text`, in source order.
      #
      # `raw_payload` is the object literal as written; it is `nil` when
      # `problem` explains why the annotation could not be captured.
      #
      # An `@intent:` token carrying no extractable payload is **reported, not
      # skipped** — a typo'd annotation must fail loudly rather than silently
      # counting as "this example is unannotated".
      #
      # @param text [String] the full source of one file
      # @yieldparam line_no [Integer] 1-based line number
      # @yieldparam raw_payload [String, nil]
      # @yieldparam problem [String, nil]
      # @return [Enumerator] when no block is given
      def each_intent(text)
        return enum_for(:each_intent, text) unless block_given?

        text.each_line.with_index(1) do |raw_line, line_no|
          line = raw_line.chomp
          pos = 0

          loop do
            token_at = line.index(INTENT_TOKEN, pos)
            break if token_at.nil?

            brace_at = line.index("{", token_at + INTENT_TOKEN.length)
            if brace_at.nil?
              yield line_no, nil, NO_PAYLOAD
              break
            end

            begin
              finish = scan_object(line, brace_at)
            rescue ScanError => e
              yield line_no, nil, e.message
              break
            end

            yield line_no, line[brace_at...finish], nil

            # Resume *after* the captured payload so trailing prose containing
            # another `@intent:` is still seen, but the payload's own contents
            # are never rescanned.
            pos = finish
          end
        end
      end

      # Returns the index just past the `}` matching the `{` at `text[start]`.
      #
      # Bracket-balanced and string-aware, so a brace inside a quoted value does
      # not end the payload early. Annotations are single-line per PROTOCOL.md
      # §1, so `text` is one line.
      #
      # @raise [ScanError] when the literal is unterminated or unbalanced
      def scan_object(text, start)
        stack = []
        i = start
        length = text.length

        while i < length
          char = text[i]

          if char == '"' || char == "'"
            i = scan_string(text, i, char)
            next
          end

          if char == "{" || char == "["
            stack.push(char)
          elsif char == "}" || char == "]"
            raise ScanError, UNBALANCED_BRACKETS if stack.empty? || stack.last != OPENERS[char]

            stack.pop
            return i + 1 if stack.empty?
          end

          i += 1
        end

        raise ScanError, UNTERMINATED_OBJECT
      end

      # Returns the index just past the closing `quote` of a string literal.
      #
      # `text[start]` must be the opening quote. Backslash escapes are honoured,
      # so a quote or brace *inside* the string never terminates the scan.
      #
      # @raise [ScanError] when the string literal is unterminated
      def scan_string(text, start, quote)
        i = start + 1
        length = text.length

        while i < length
          char = text[i]

          if char == "\\"
            i += 2 # skip the escape and whatever it escapes
            next
          end

          return i + 1 if char == quote

          i += 1
        end

        raise ScanError, "unterminated #{quote}-quoted string"
      end
    end
  end
end
