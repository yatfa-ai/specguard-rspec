# frozen_string_literal: true

# The renderer is where message parity is actually won, so these examples pin
# its *structure* rather than only the four shipped fixtures: the ordering
# rule, the re-attribution of `additionalProperties`, the type-mismatch cutoff,
# and Python's `%r`. A schema that grows a keyword, or a payload shape the
# corpus does not contain, has to keep behaving.
RSpec.describe SpecGuard::RSpec::ViolationRenderer do
  subject(:renderer) { described_class.new }

  def render(schema_document, instance)
    errors = JSONSchemer.schema(schema_document).validate(instance).to_a
    renderer.render(errors, instance)
  end

  let(:v1) { JSON.parse(File.read(SpecGuard::RSpec::SCHEMA_PATH)) }

  describe "it renders from structured fields, not from json_schemer's sentence" do
    # If any of these leaked through, the output would read
    # "value at `/layer` is not one of: [...]" — and would change silently on a
    # gem bump.
    it "never emits json_schemer's own phrasing for a keyword it knows" do
      violations = render(v1, "entiity" => "Order", "action" => "t", "behavior" => "x", "layer" => "e2e")

      expect(violations.join("\n")).not_to include("value at `", "object at root", "string length at `")
    end
  end

  describe "ordering reproduces the reference walker" do
    # bin/validate-intent:150-210 evaluates, per node: type, enum, every
    # missing required key in SCHEMA order, then each instance property in
    # INSERTION order. json_schemer's own order is different for all three.
    it "puts required before the instance's own properties" do
      expect(render(v1, "behavior" => "sums")).to eq([
                                                       "<root>: missing required property 'entity'",
                                                       "<root>: missing required property 'action'",
                                                       "<root>: missing required property 'layer'",
                                                       "behavior: string is 4 char(s), minLength is 15"
                                                     ])
    end

    it "orders property violations by where the property appears in the instance" do
      # `layer` is written before `behavior` here, and the output follows the
      # payload rather than the schema's property order.
      violations = render(v1, "entity" => "Order", "action" => "total",
                              "layer" => "e2e", "behavior" => "sums")

      expect(violations).to eq([
                                 "layer: value 'e2e' is not one of ['unit', 'integration', 'request', 'system']",
                                 "behavior: string is 4 char(s), minLength is 15"
                               ])
    end

    it "keeps a disallowed additional property in the instance's property order" do
      # `zzz` is written first, so it is reported before the later `behavior`
      # violation even though "additional property" errors are conceptually
      # about the root.
      violations = render(v1, "zzz" => 1, "entity" => "Order", "action" => "total",
                              "behavior" => "sums", "layer" => "unit")

      expect(violations).to eq([
                                 "<root>: additional property 'zzz' is not allowed",
                                 "behavior: string is 4 char(s), minLength is 15"
                               ])
    end
  end

  describe "additionalProperties, which arrives disguised" do
    # json_schemer reports it as type "schema" (schema_pointer
    # /additionalProperties, schema literally `false`) with data_pointer on the
    # OFFENDING PROPERTY. Dispatching on a guessed "additionalProperties" type
    # renders nothing at all — silently, which is the worst possible failure
    # for a linter.
    it "renders it, despite json_schemer calling the error type 'schema'" do
      payload = { "entiity" => "Order", "action" => "checkout",
                  "behavior" => "returns 402 payment required on expired card", "layer" => "request" }
      raw = JSONSchemer.schema(v1).validate(payload).to_a
      additional = raw.find { |e| e["data_pointer"] == "/entiity" }

      expect(additional["type"]).to eq("schema") # the disguise, pinned
      expect(renderer.render([additional], payload))
        .to eq(["<root>: additional property 'entiity' is not allowed"])
    end

    it "attributes it to the object that disallowed it, not to the property" do
      nested = {
        "type" => "object",
        "properties" => { "meta" => { "type" => "object", "additionalProperties" => false, "properties" => {} } }
      }

      expect(render(nested, "meta" => { "oops" => 1 }))
        .to eq(["meta: additional property 'oops' is not allowed"])
    end

    # The disguise is broader than the name: json_schemer reports type "schema"
    # for ANY subschema that rejected the instance without a more specific
    # keyword — a literal `false` schema, an unmatched `not` — not only
    # `additionalProperties: false`. Today that is safe because the v1 schema
    # contains exactly one such subschema, but this contract is the oracle the
    # Go binary is graded against, so the guard is narrowed on the
    # schema_pointer. A DECLARED property rejected by a `false` schema is not
    # an "additional property", and saying so would blame the wrong node with
    # the wrong words.
    it "does not call a non-additionalProperties subschema an additional property" do
      falsey = { "type" => "object", "properties" => { "a" => false } }
      payload = { "a" => 1 }
      raw = JSONSchemer.schema(falsey).validate(payload).to_a

      expect(raw.first["type"]).to eq("schema") # same disguise, different cause
      expect(raw.first["schema_pointer"]).to eq("/properties/a")

      violations = render(falsey, "a" => 1)

      expect(violations.length).to eq(1)
      expect(violations.first).to start_with("a: ")
      expect(violations.first).not_to include("additional property")
    end
  end

  describe "a type mismatch silences the rest of its node" do
    # The reference returns immediately: "a type mismatch makes the remaining
    # keywords moot". json_schemer keeps going and reports the enum too, so
    # both tools reject `layer: 123` but would describe it differently.
    it "reports only the type error for a non-string layer" do
      expect(render(v1, "entity" => "Order", "action" => "total",
                        "behavior" => "sums line item prices ok", "layer" => 123))
        .to eq(["layer: expected type string, got number"])
    end

    it "silences violations beneath the mistyped node as well" do
      nested = {
        "type" => "object",
        "properties" => {
          "meta" => { "type" => "object", "required" => %w[a], "properties" => { "a" => { "type" => "string" } } }
        }
      }

      expect(render(nested, "meta" => "not an object")).to eq(["meta: expected type object, got string"])
    end

    it "still reports violations at sibling nodes" do
      expect(render(v1, "entity" => "Order", "action" => "total", "behavior" => "sums", "layer" => 123))
        .to eq([
                 "behavior: string is 4 char(s), minLength is 15",
                 "layer: expected type string, got number"
               ])
    end

    it "names a union type the way the reference joins it" do
      union = { "type" => "object", "properties" => { "a" => { "type" => %w[string null] } } }

      expect(render(union, "a" => 1)).to eq(["a: expected type string|null, got number"])
    end
  end

  describe "array paths" do
    it "renders an item's path with brackets, as the reference does" do
      expect(render(v1, "entity" => "Order", "action" => "total",
                        "behavior" => "sums line item prices ok", "layer" => "unit",
                        "preconditions" => ["ok", 5]))
        .to eq(["preconditions[1]: expected type string, got number"])
    end
  end

  describe "Python's %r, which the reference interpolates values with" do
    def enum_violation(value)
      render({ "type" => "object", "properties" => { "k" => { "enum" => %w[a b] } } }, "k" => value).first
    end

    it "single-quotes an ordinary string" do
      expect(enum_violation("zzz")).to eq("k: value 'zzz' is not one of ['a', 'b']")
    end

    it "switches to double quotes when the value contains an apostrophe" do
      expect(enum_violation("it's")).to eq(%{k: value "it's" is not one of ['a', 'b']})
    end

    it "escapes the quote when the value contains both kinds" do
      expect(enum_violation(%(it's "x"))).to eq(%{k: value 'it\\'s "x"' is not one of ['a', 'b']})
    end

    it "escapes a backslash and a newline" do
      expect(enum_violation("a\\b\nc")).to eq("k: value 'a\\\\b\\nc' is not one of ['a', 'b']")
    end

    it "spells Ruby's nil and booleans the Python way" do
      expect(enum_violation(nil)).to eq("k: value None is not one of ['a', 'b']")
      expect(enum_violation(true)).to eq("k: value True is not one of ['a', 'b']")
    end
  end

  describe "keywords the v1 schema does not use yet" do
    # The schema is versioned and will grow. Every one of these is phrased the
    # reference's way so parity survives the next schema revision.
    it "renders maxLength, pattern, minItems, maxItems, minimum and maximum" do
      grown = {
        "type" => "object",
        "properties" => {
          "a" => { "type" => "string", "maxLength" => 2 },
          "b" => { "type" => "string", "pattern" => "^z" },
          "c" => { "type" => "array", "minItems" => 2 },
          "d" => { "type" => "array", "maxItems" => 1 },
          "e" => { "type" => "number", "minimum" => 5 },
          "f" => { "type" => "number", "maximum" => 1 }
        }
      }

      expect(render(grown, "a" => "abc", "b" => "q", "c" => [1], "d" => [1, 2], "e" => 3, "f" => 9))
        .to eq([
                 "a: string is 3 char(s), maxLength is 2",
                 "b: string does not match pattern '^z'",
                 "c: array has 1 item(s), minimum is 2",
                 "d: array has 2 item(s), maximum is 1",
                 "e: value 3 is below minimum 5",
                 "f: value 9 is above maximum 1"
               ])
    end

    # A violation this renderer cannot phrase must still be REPORTED. Dropping
    # it would turn a malformed annotation into a clean run — the exact
    # false-green this ticket's contract exists to make impossible.
    it "falls back to json_schemer's own sentence rather than dropping a violation" do
      exotic = { "type" => "object", "properties" => { "a" => { "multipleOf" => 3 } } }

      violations = render(exotic, "a" => 4)

      expect(violations.length).to eq(1)
      expect(violations.first).to start_with("a: ")
    end
  end
end
