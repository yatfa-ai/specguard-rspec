# frozen_string_literal: true

# Criterion 7: **message parity**. The roadmap's goal is that "client and
# platform agree on what's valid" — which is worth very little if the two tools
# agree on the verdict and then describe it differently, because what a human
# and a CI log diff actually see is the text.
#
# The corpus is open-test-intent's own `examples/` and `examples/invalid/`,
# copied byte-for-byte into `spec/fixtures/payloads/` (from `c8f5b6d`). Copies,
# deliberately: the roadmap forbids a cross-repo runtime dependency and the
# same reasoning applies to the suite — a spec that shells out to the Python
# validator would pass on this container and be unrunnable anywhere else.
#
# Every expected string below was captured by **executing**
# `python3 bin/validate-intent <fixture>` against the reference, not
# transcribed from a spec document. If json_schemer changes its wording on a
# gem bump, these fail — which is the point: the renderer builds text from the
# gem's structured fields precisely so that drift is impossible, and this is
# the assertion that proves it stayed impossible.
RSpec.describe "message parity with open-test-intent's bin/validate-intent" do
  subject(:schema) { SpecGuard::RSpec::Schema.load }

  def payload(name) = payload_fixture(name)

  # The four invalid payloads, with the reference's exact output for each —
  # text AND order.
  REFERENCE_OUTPUT = {
    "invalid/bad-layer.json" => [
      "layer: value 'e2e' is not one of ['unit', 'integration', 'request', 'system']"
    ],
    "invalid/missing-required.json" => [
      "<root>: missing required property 'action'"
    ],
    "invalid/short-behavior.json" => [
      "behavior: string is 5 char(s), minLength is 15"
    ],
    # Order matters and is the opposite of json_schemer's: the reference emits
    # every missing `required` key before it iterates the instance's own
    # properties, so `required` precedes `additionalProperties`. Raw
    # json_schemer emits the additional property first.
    "invalid/typo-extra-property.json" => [
      "<root>: missing required property 'entity'",
      "<root>: additional property 'entiity' is not allowed"
    ]
  }.freeze

  REFERENCE_OUTPUT.each do |name, expected|
    it "renders #{name} exactly as the reference does" do
      expect(schema.violations(payload(name))).to eq(expected)
    end
  end

  # Verdict parity is the structurally safe half — the v1 schema uses only
  # keywords both implementations support — but "structurally safe" is a claim,
  # and a claim in a comment is not a test.
  %w[
    unit-order-total.json
    unit-checkout-service.json
    request-orders-checkout.json
    system-checkout-flow.json
  ].each do |name|
    it "accepts #{name}, as the reference does" do
      expect(schema.violations(payload(name))).to be_empty
    end
  end

  REFERENCE_OUTPUT.each_key do |name|
    it "rejects #{name}, as the reference does" do
      expect(schema.violations(payload(name))).not_to be_empty
    end
  end

  describe "the two divergences that are not wording" do
    # json_schemer batches every missing key into ONE error carrying
    # `details.missing_keys = ["action", "layer"]`. The reference loops
    # (bin/validate-intent:163-165) and prints one line each. Passing the
    # batched error through would under-report, and a developer would fix
    # `action`, re-run CI, and only then learn about `layer`.
    it "fans a batched missing_keys error out to one line per key" do
      violations = schema.violations("entity" => "Order",
                                     "behavior" => "returns 402 payment required on expired card")

      expect(violations).to eq([
                                 "<root>: missing required property 'action'",
                                 "<root>: missing required property 'layer'"
                               ])
    end

    it "orders those lines by the schema's own required array, not alphabetically" do
      # `entity` precedes `action` in `required`, and would follow it if these
      # were sorted by name.
      violations = schema.violations("behavior" => "returns 402 payment required on expired card",
                                     "layer" => "unit")

      expect(violations).to eq([
                                 "<root>: missing required property 'entity'",
                                 "<root>: missing required property 'action'"
                               ])
    end

    # `broken_intent_spec.rb:21` — the reference emits `required` then
    # `minLength`; json_schemer emits them the other way round.
    it "puts a missing required key before a violation of a property that IS present" do
      violations = schema.violations("entity" => "Order", "action" => "total", "behavior" => "sums")

      expect(violations).to eq([
                                 "<root>: missing required property 'layer'",
                                 "behavior: string is 4 char(s), minLength is 15"
                               ])
    end
  end
end
