# spec/models/broken_intent_spec.rb
#
# Fixture: every @intent annotation in this file MUST be rejected, each reported
# at its own file:line. This is the expected-invalid counterpart to
# examples/sources/*.rb, mirroring examples/invalid/*.json.

RSpec.describe Order do
  # Typo'd key — `additionalProperties: false` must catch `entiity`.
  # @intent: { entiity: "Order", action: "total", behavior: "sums line item prices after the discount", layer: "unit" }
  it "sums line items" do
    expect(order.total).to eq(90)
  end

  # `layer` outside the enum.
  # @intent: { entity: 'Order', action: 'total', behavior: 'sums line item prices after the discount', layer: 'model' }
  it "sums line items again" do
    expect(order.total).to eq(90)
  end

  # Missing a required key (`layer`) and a `behavior` under minLength: 15.
  # @intent: {entity:"Order",action:"total",behavior:"sums"}
  it "sums line items compactly" do
    expect(order.total).to eq(90)
  end

  # Unterminated object literal — an annotation must fit on one line, so this is
  # reported as a malformed annotation rather than silently treated as absent.
  # @intent: { entity: "Order", action: "total",
  it "is not silently skipped" do
    expect(order.total).to eq(90)
  end

  # An `@intent` marker with no payload at all — also reported, not skipped.
  # @intent:
  it "is also not silently skipped" do
    expect(order.total).to eq(90)
  end
end
