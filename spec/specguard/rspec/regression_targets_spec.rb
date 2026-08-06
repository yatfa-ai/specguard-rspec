# frozen_string_literal: true

# The four edge-case lines in the valid fixture, plus the bare-word rule.
#
# These are the cases a `gsub`-then-`JSON.parse` normalizer gets WRONG. They are
# pinned individually — rather than only via the corpus counts — so a regression
# names the specific behavior it broke instead of just moving a total from 7
# to 6.
RSpec.describe "permissive-syntax regression targets" do
  def intent_from(line)
    findings = SpecGuard::RSpec::Scanner.scan_text(line, file: "example_spec.rb")
    expect(findings.length).to eq(1)
    expect(findings.first.problem).to be_nil
    findings.first.intent
  end

  # order_spec.rb:32 — the `\'` must be unescaped into a plain `'` rather than
  # ending the string early. `\'` is meaningless in JSON, so re-emitting it
  # verbatim would produce an invalid escape.
  it "unescapes \\' inside a single-quoted value (:32)" do
    line = %q{  # @intent: { entity: 'Order', action: 'checkout', behavior: 'reports the card\'s expiry date in the decline notice', layer: 'request' }}

    expect(intent_from(line)["behavior"]).to eq("reports the card's expiry date in the decline notice")
  end

  # order_spec.rb:41 — PROTOCOL.md §1 allows same-line placement. Neither the
  # `}` nor the `'` inside the quoted value may terminate the payload early.
  it "extracts an annotation placed after code on the same line (:41)" do
    line = %q{  it "surfaces the decline reason" do # @intent: { entity: "Order", action: "checkout", behavior: "renders the gateway's decline reason in the {error} slot", layer: "request" }}

    expect(intent_from(line)["behavior"]).to eq("renders the gateway's decline reason in the {error} slot")
  end

  # order_spec.rb:49 — the case plain brace-counting gets wrong. The `{` in the
  # sentence is never balanced, so a depth counter that is not string-aware
  # runs off the end of the line and reports a spurious problem.
  #
  # NOTE the `%q(...)` delimiter: this line cannot be written with `%q{...}`
  # precisely because the brace it is testing is unbalanced.
  it "ignores an unbalanced { inside a quoted value (:49)" do
    line = %q(  # @intent: { entity: "Order", action: "checkout", behavior: "returns 400 when the JSON body is truncated after the opening {", layer: "request" })

    expect(intent_from(line)["behavior"]).to eq("returns 400 when the JSON body is truncated after the opening {")
  end

  # order_spec.rb:57 — capture stops at the *matching* brace, so trailing prose
  # (braces and all) is not swallowed into the payload.
  it "stops at the matching brace and ignores trailing prose containing braces (:57)" do
    line = %q{  # @intent: { entity: "Order", action: "refund", behavior: "restores stock levels when a paid order is refunded", layer: "unit" } — see ADR-14 {§3} for why this is unit, not request.}

    expect(intent_from(line)).to eq(
      "entity" => "Order",
      "action" => "refund",
      "behavior" => "restores stock levels when a paid order is refunded",
      "layer" => "unit"
    )
  end

  # The protocol relaxes keys and quote style, never *value* quoting. A bare
  # word in value position must survive normalization unquoted so it still
  # fails — quoting it here would silently turn an invalid annotation valid.
  describe "the bare-word rule" do
    it "quotes a bare word in key position" do
      expect(SpecGuard::RSpec::PayloadNormalizer.normalize('{entity: "Order"}')).to eq('{"entity": "Order"}')
    end

    it "leaves a bare word in value position unquoted" do
      expect(SpecGuard::RSpec::PayloadNormalizer.normalize("{layer: request}")).to eq('{"layer": request}')
    end

    it "so an unquoted value is reported as a parse problem, not accepted" do
      findings = SpecGuard::RSpec::Scanner.scan_text("# @intent: {layer: request}", file: "example_spec.rb")

      expect(findings.first.intent).to be_nil
      expect(findings.first.kind).to eq(SpecGuard::RSpec::Finding::KIND_PARSE)
      expect(findings.first.problem).to start_with("could not parse annotation:")
    end
  end

  # The payload is text from a comment in someone's spec file — i.e. it is
  # attacker-controllable. It must only ever reach JSON.parse, never eval.
  it "never evaluates the payload" do
    line = %q{# @intent: { entity: "#{raise 'code executed'}", action: 'x', behavior: 'y', layer: 'unit' }}

    expect { SpecGuard::RSpec::Scanner.scan_text(line, file: "evil_spec.rb") }.not_to raise_error
    expect(intent_from(line)["entity"]).to eq('#{raise \'code executed\'}')
  end
end
