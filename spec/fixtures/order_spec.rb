# spec/requests/orders_spec.rb
#
# Fixture: the three "Equivalent forms" from PROTOCOL.md §1 as they appear in
# real test source. All three must extract, normalize and validate identically.

require "rails_helper"

RSpec.describe "POST /orders/checkout" do
  # Form 1 — double-quoted keys and strings (already strict JSON).
  # @intent: { "entity": "Order", "action": "checkout", "behavior": "returns 402 payment required on expired card", "layer": "request" }
  it "rejects checkout on an expired card" do
    post "/orders/checkout", params: { card_id: expired_card.id }
    expect(response).to have_http_status(:payment_required)
  end

  # Form 2 — single-quoted keys and strings.
  # @intent: { entity: 'Order', action: 'checkout', behavior: 'returns 402 payment required on expired card', layer: 'request' }
  it "rejects checkout on an expired card (single-quoted annotation)" do
    post "/orders/checkout", params: { card_id: expired_card.id }
    expect(response).to have_http_status(:payment_required)
  end

  # Form 3 — unquoted keys, no whitespace.
  # @intent: {entity:"Order",action:"checkout",behavior:"returns 402 payment required on expired card",layer:"request"}
  it "rejects checkout on an expired card (compact annotation)" do
    post "/orders/checkout", params: { card_id: expired_card.id }
    expect(response).to have_http_status(:payment_required)
  end

  # Single-quoted with an escaped apostrophe inside the value — the `\'` must be
  # unescaped into a plain `'` rather than ending the string early.
  # @intent: { entity: 'Order', action: 'checkout', behavior: 'reports the card\'s expiry date in the decline notice', layer: 'request' }
  it "names the expiry date in the decline notice" do
    post "/orders/checkout", params: { card_id: expired_card.id }
    expect(response.body).to include("expired on")
  end

  # Same-line placement (PROTOCOL.md §1 allows it) with a braces-and-apostrophe
  # behavior sentence — the extractor is string-aware, so neither the `}` nor
  # the `'` inside the quoted value terminates the payload early.
  it "surfaces the decline reason" do # @intent: { entity: "Order", action: "checkout", behavior: "renders the gateway's decline reason in the {error} slot", layer: "request" }
    post "/orders/checkout", params: { card_id: expired_card.id }
    expect(response.body).to include("card expired")
  end

  # An *unbalanced* brace inside the quoted value — realistic for a spec about
  # malformed payloads, and the case plain brace-counting gets wrong. Capture is
  # string-aware, so the `{` in the sentence never enters the depth count.
  # @intent: { entity: "Order", action: "checkout", behavior: "returns 400 when the JSON body is truncated after the opening {", layer: "request" }
  it "rejects a truncated JSON body" do
    post "/orders/checkout", params: "{", headers: json_headers
    expect(response).to have_http_status(:bad_request)
  end

  # Trailing prose after the payload — capture stops at the matching brace, so
  # the rest of the comment (braces and all) is not swallowed into the payload.
  # @intent: { entity: "Order", action: "refund", behavior: "restores stock levels when a paid order is refunded", layer: "unit" } — see ADR-14 {§3} for why this is unit, not request.
  it "restores stock on refund" do
    expect { order.refund! }.to change { order.line_items.first.sku.stock }.by(1)
  end
end
