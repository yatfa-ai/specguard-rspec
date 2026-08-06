# frozen_string_literal: true

module SpecGuard
  module RSpec
    # Renders `json_schemer`'s structured validation errors in the grammar and
    # the order used by open-test-intent's `bin/validate-intent`.
    #
    # == Why not just print json_schemer's own message?
    #
    # Because the protocol repo ships a validator, and "client and platform
    # agree on what's valid" is worth very little if the two tools *say*
    # different things about the same annotation. The verdicts already agree:
    # the v1 schema uses only `type` / `enum` / `required` /
    # `additionalProperties` / `properties` / `items` / `minLength`, all of
    # which both implementations support. The *messages* do not agree at all:
    #
    #   reference   layer: value 'e2e' is not one of ['unit', 'integration', ...]
    #   json_schemer  value at `/layer` is not one of: ["unit", "integration", ...]
    #
    # So the text is rebuilt here. It is rebuilt from the **structured** fields
    # of each error (`type`, `data_pointer`, `schema`, `details.missing_keys`)
    # and never by string-munging `error["error"]`: that sentence is
    # gem-version-dependent, so a `json_schemer` bump would silently drift the
    # output away from the reference. Structured fields are the gem's API;
    # the sentence is not.
    #
    # == Three divergences that are not wording
    #
    # 1. **Order.** json_schemer emits in its own traversal order —
    #    `additionalProperties` before `required`, `minLength` before
    #    `required`. The reference walks the document deliberately (see
    #    `validate` at `bin/validate-intent:150-210`): per node, `type`, then
    #    `enum`, then every missing `required` key in *schema* order, then each
    #    instance property in *insertion* order (recursing, or reporting the
    #    disallowed additional property), then array, string and number
    #    keywords. {#render} reproduces that traversal as a sort key rather
    #    than re-walking the document, so the two tools list the same
    #    violations in the same sequence.
    #
    # 2. **Cardinality.** Two missing required keys are one json_schemer error
    #    carrying `details.missing_keys = ["action", "layer"]`; the reference
    #    prints one line per key (its loop at `bin/validate-intent:163-165`).
    #    The batch is fanned back out here.
    #
    # 3. **`additionalProperties` does not have the type you would guess.** It
    #    arrives as `type: "schema"` (schema_pointer `/additionalProperties`,
    #    `schema` literally `false`) with `data_pointer` on the *offending
    #    property* — `/entiity`, not the object that disallowed it. A renderer
    #    dispatching on a guessed `"additionalProperties"` would render nothing
    #    for this case, silently. The error is re-attributed to the parent
    #    object here, which is what makes the reference's `<root>: additional
    #    property 'entiity' is not allowed` come out.
    #
    # A fourth, smaller one: the reference `return`s as soon as a node's `type`
    # is wrong ("a type mismatch makes the remaining keywords moot"), while
    # json_schemer reports the type failure *and* every other keyword at that
    # node — a non-string `layer` yields both a type and an `enum` error. See
    # {#drop_shadowed_by_type_mismatch}.
    class ViolationRenderer
      # What the reference calls the document root in a message.
      ROOT = "<root>"

      # Keyword ranks within one node, in the reference's evaluation order.
      # Children start at CHILD_BASE so every keyword of a node sorts before
      # any of its descendants — which is exactly what `required`-before-
      # property-iteration means.
      RANK_TYPE = 0
      RANK_ENUM = 1
      RANK_REQUIRED = 2
      RANK_MIN = 3 # minItems / minLength / minimum — instance types are disjoint
      RANK_MAX = 4 # maxItems / maxLength / maximum
      RANK_PATTERN = 5
      RANK_UNKNOWN = 9
      CHILD_BASE = 10

      # `type` values json_schemer uses for a failed `type` keyword. A union
      # (`"type": ["string", "null"]`) reports the literal `"type"` instead.
      JSON_TYPE_NAMES = %w[object array string integer number boolean null].freeze

      TYPE_KEYWORD = "type"
      REQUIRED_KEYWORD = "required"
      # json_schemer's error `type` for a subschema that rejected the instance
      # without a more specific keyword to blame. `additionalProperties: false`
      # is one such subschema — and the only one the v1 schema contains — but
      # a literal `false` schema or an unmatched `not` reports identically.
      # The name is deliberately the general one; {#additional_properties?} is
      # what narrows it, so a schema revision that grows a `not` renders
      # json_schemer's sentence instead of a nonsense "additional property"
      # line about a property that was declared.
      SUBSCHEMA_KEYWORD = "schema"
      ADDITIONAL_PROPERTIES_POINTER = "/additionalProperties"

      # One rendered line, plus where it came from and where it sorts.
      #
      # `pointer` is the node the *reference* attributes the message to, which
      # for an additional-property violation is the parent object rather than
      # json_schemer's `data_pointer`.
      Entry = Data.define(:pointer, :sort_key, :message, :type_mismatch)

      # @param errors [Enumerable<Hash>] raw `json_schemer` error hashes
      # @param instance [Object] the document that was validated. Needed for
      #   ordering: the reference iterates an object's properties in insertion
      #   order, which only the instance knows.
      # @return [Array<String>] reason lines, reference grammar, reference order
      def render(errors, instance)
        entries = errors.each_with_index.flat_map { |error, seq| entries_for(error, instance, seq) }

        drop_shadowed_by_type_mismatch(entries).sort_by(&:sort_key).map(&:message)
      end

      private

      def entries_for(error, instance, seq)
        pointer = error["data_pointer"].to_s
        keyword = error["type"]

        case keyword
        when REQUIRED_KEYWORD then required_entries(error, pointer, instance, seq)
        when SUBSCHEMA_KEYWORD then [subschema_entry(error, pointer, instance, seq)]
        when "enum" then [enum_entry(error, pointer, instance, seq)]
        when "minLength", "maxLength" then [length_entry(error, keyword, pointer, instance, seq)]
        when "pattern" then [pattern_entry(error, pointer, instance, seq)]
        when "minItems", "maxItems" then [items_entry(error, keyword, pointer, instance, seq)]
        when "minimum", "maximum" then [bound_entry(error, keyword, pointer, instance, seq)]
        else
          if type_mismatch?(keyword)
            [type_entry(error, pointer, instance, seq)]
          else
            [unknown_entry(error, pointer, instance, seq)]
          end
        end
      end

      def type_mismatch?(keyword)
        keyword == TYPE_KEYWORD || JSON_TYPE_NAMES.include?(keyword)
      end

      # One line per missing key, ordered by the key's position in the schema's
      # own `required` array — the order the reference's loop visits them in.
      def required_entries(error, pointer, instance, seq)
        schema = error["schema"]
        declared = schema.is_a?(Hash) ? Array(schema[REQUIRED_KEYWORD]) : []
        missing = error.dig("details", "missing_keys") || []

        missing.map do |name|
          entry(pointer, instance, [RANK_REQUIRED, declared.index(name) || declared.length, seq],
                "#{label(pointer, instance)}: missing required property '#{name}'")
        end
      end

      # Re-attributed to the parent: json_schemer points at the property, the
      # reference blames the object that disallowed it.
      #
      # Only a violation of `additionalProperties` itself gets that treatment.
      # Any other rejecting subschema is about the property the pointer names,
      # so re-attributing it would move the blame to the wrong node *and*
      # phrase it as something it is not.
      def subschema_entry(error, pointer, instance, seq)
        return unknown_entry(error, pointer, instance, seq) unless additional_properties?(error)

        additional_property_entry(pointer, instance, seq)
      end

      def additional_properties?(error)
        error["schema_pointer"].to_s.end_with?(ADDITIONAL_PROPERTIES_POINTER)
      end

      def additional_property_entry(pointer, instance, seq)
        parent, name = split_pointer(pointer)

        entry(parent, instance, [child_rank(parent, name, instance), 0, seq],
              "#{label(parent, instance)}: additional property '#{name}' is not allowed")
      end

      def enum_entry(error, pointer, instance, seq)
        allowed = error.dig("schema", "enum")

        entry(pointer, instance, [RANK_ENUM, seq],
              "#{label(pointer, instance)}: value #{py_repr(error['data'])} is not one of #{py_repr(allowed)}")
      end

      def length_entry(error, keyword, pointer, instance, seq)
        rank = keyword == "minLength" ? RANK_MIN : RANK_MAX

        entry(pointer, instance, [rank, seq],
              "#{label(pointer, instance)}: string is #{error['data'].length} char(s), " \
              "#{keyword} is #{error.dig('schema', keyword)}")
      end

      def pattern_entry(error, pointer, instance, seq)
        entry(pointer, instance, [RANK_PATTERN, seq],
              "#{label(pointer, instance)}: string does not match pattern #{py_repr(error.dig('schema', 'pattern'))}")
      end

      def items_entry(error, keyword, pointer, instance, seq)
        rank = keyword == "minItems" ? RANK_MIN : RANK_MAX
        bound = keyword == "minItems" ? "minimum" : "maximum"

        entry(pointer, instance, [rank, seq],
              "#{label(pointer, instance)}: array has #{error['data'].length} item(s), " \
              "#{bound} is #{error.dig('schema', keyword)}")
      end

      def bound_entry(error, keyword, pointer, instance, seq)
        rank = keyword == "minimum" ? RANK_MIN : RANK_MAX
        direction = keyword == "minimum" ? "below minimum" : "above maximum"

        entry(pointer, instance, [rank, seq],
              "#{label(pointer, instance)}: value #{py_repr(error['data'])} is " \
              "#{direction} #{py_repr(error.dig('schema', keyword))}")
      end

      def type_entry(error, pointer, instance, seq)
        allowed = Array(error.dig("schema", TYPE_KEYWORD)).join("|")

        entry(pointer, instance, [RANK_TYPE, seq],
              "#{label(pointer, instance)}: expected type #{allowed}, got #{json_type_of(error['data'])}",
              type_mismatch: true)
      end

      # A keyword the schema grew that nothing here knows how to phrase. The
      # violation is real, so it is reported using json_schemer's own sentence
      # rather than dropped — an unrenderable violation that vanishes would
      # turn a malformed annotation into a clean run, which is the exact
      # failure mode this whole ticket exists to prevent.
      def unknown_entry(error, pointer, instance, seq)
        entry(pointer, instance, [RANK_UNKNOWN, seq], "#{label(pointer, instance)}: #{error['error']}")
      end

      def entry(pointer, instance, tail, message, type_mismatch: false)
        Entry.new(pointer: pointer, message: message, type_mismatch: type_mismatch,
                  sort_key: prefix_for(pointer, instance) + tail)
      end

      # The reference bails out of a node the moment its `type` is wrong
      # ("a type mismatch makes the remaining keywords moot"), so nothing else
      # at that node — or anywhere beneath it — is ever printed. json_schemer
      # keeps going. Without this, a `layer: 123` would emit both
      # "expected type string, got number" and the enum line, and the two tools
      # would disagree on a case they both correctly reject.
      def drop_shadowed_by_type_mismatch(entries)
        shadowed = entries.select(&:type_mismatch).map(&:pointer).uniq
        return entries if shadowed.empty?

        entries.reject do |candidate|
          !candidate.type_mismatch &&
            shadowed.any? { |at| candidate.pointer == at || candidate.pointer.start_with?("#{at}/") }
        end
      end

      # The sort key's path component: one element per step from the root, each
      # the position of that step among its parent's children. Two errors under
      # the same parent therefore order by where their properties appear in the
      # instance — insertion order for a Hash, index order for an Array —
      # which is the order the reference's property loop visits them in.
      def prefix_for(pointer, instance)
        node = instance

        pointer_tokens(pointer).map do |token|
          position = CHILD_BASE + child_index(node, token)
          node = child_of(node, token)
          position
        end
      end

      def child_rank(parent_pointer, name, instance)
        CHILD_BASE + child_index(node_at(parent_pointer, instance), name)
      end

      # Unknown children sort last rather than raising: a pointer that does not
      # resolve is a bug in this renderer, not a reason to abandon the report.
      def child_index(node, token)
        case node
        when Hash then node.keys.index(token) || node.size
        when Array then token.to_i
        else 0
        end
      end

      def child_of(node, token)
        case node
        when Hash then node[token]
        when Array then node[token.to_i]
        end
      end

      def node_at(pointer, instance)
        pointer_tokens(pointer).reduce(instance) { |node, token| child_of(node, token) }
      end

      # The reference's name for a node: `<root>`, `behavior`, `a.b`,
      # `preconditions[0]` — dotted for object properties, bracketed for array
      # indices. Array-ness is read off the instance, not guessed from the
      # token, so an object whose key happens to be `"0"` still renders dotted.
      def label(pointer, instance)
        node = instance
        rendered = +""

        pointer_tokens(pointer).each do |token|
          if node.is_a?(Array)
            rendered << "[#{token}]"
          else
            rendered << "." unless rendered.empty?
            rendered << token
          end
          node = child_of(node, token)
        end

        rendered.empty? ? ROOT : rendered
      end

      # @return [[String, String]] the pointer's parent and its last token
      def split_pointer(pointer)
        tokens = pointer_tokens(pointer)
        [pointer.split("/")[0...-1].join("/"), tokens.last.to_s]
      end

      # RFC 6901: `~1` is `/` and `~0` is `~`, in that order.
      def pointer_tokens(pointer)
        return [] if pointer.nil? || pointer.empty?

        pointer.split("/", -1).drop(1).map { |token| token.gsub("~1", "/").gsub("~0", "~") }
      end

      def json_type_of(value)
        case value
        when true, false then "boolean"
        when String then "string"
        when Hash then "object"
        when Array then "array"
        when Numeric then "number"
        when nil then "null"
        else value.class.name
        end
      end

      PY_ESCAPES = { "\\" => "\\\\", "\n" => "\\n", "\r" => "\\r", "\t" => "\\t" }.freeze

      # Python's `%r`, which is what the reference interpolates values with.
      # Getting this wrong is not cosmetic: `value 'e2e' is not one of [...]`
      # is a line CI logs get diffed on.
      def py_repr(value)
        case value
        when String then py_repr_string(value)
        when Array then "[#{value.map { |item| py_repr(item) }.join(', ')}]"
        when true then "True"
        when false then "False"
        when nil then "None"
        when Integer then value.to_s
        else value.inspect
        end
      end

      # Python prefers single quotes, and switches to double only when the
      # string contains a `'` but no `"`. Non-ASCII is left as written (Python 3
      # does not escape printable non-ASCII); C0 controls become `\xNN`.
      def py_repr_string(string)
        quote = string.include?("'") && !string.include?('"') ? '"' : "'"

        body = string.each_char.map do |char|
          next PY_ESCAPES[char] if PY_ESCAPES.key?(char)
          next "\\#{char}" if char == quote
          next format("\\x%02x", char.ord) if char.ord < 0x20 || char.ord == 0x7f

          char
        end.join

        "#{quote}#{body}#{quote}"
      end
    end
  end
end
