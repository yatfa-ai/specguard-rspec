# CONVERGENCE fixture: the payloads that used to be classified differently by
# the two backends, and are not any more.
#
# Every annotation below was once a member of a set the gem's `JSON.parse`
# refused and the binary accepted. The binary accepted them because its parser
# was built to reproduce a foreign runtime's grammar rather than the protocol's;
# PROTOCOL.md §1.1 now states the grammar, and refuses all of them:
#
#   * a non-finite literal (`NaN` / `Infinity` / `-Infinity`) — §1.1(b)
#   * an unpaired high surrogate escape                       — §1.1(a)
#   * nesting past 100 levels                                 — §1.1(c)
#
# So both backends now report KIND_PARSE for every one of them, at the same
# line, with the same counts and the same exit code. What is left is the
# WORDING of the failure — two JSON parsers spelling the same refusal
# differently — which is the tail difference ratified further up the spec file.
# Nothing here is a classification difference any more.
#
# This file is kept, rather than deleted along with the divergence, because it
# is the only place the convergence is asserted. Delete it and a binary that
# went back to accepting these payloads would take the gem's own record of why
# that is wrong with it.
#
# See spec/fixtures/validator/acceptance-set-kind.json for this file's recorded
# report, and `Scanner#parse` for what the gem's own parser accepts.
#
# The first annotation is valid on purpose: a file of nothing but failures would
# compare two reports that agree only about what broke.

# @intent: { entity: "Order", action: "create", behavior: "creates an order from a valid cart", layer: "unit" }
# @intent: { "entity": "Order", "action": "create", "behavior": "creates an order from a valid cart", "layer": "unit", "x": NaN }
# @intent: { "entity": "Order", "action": "create", "behavior": "creates an order from a valid cart", "layer": "unit", "x": Infinity }
# @intent: { "entity": "Order", "action": "create", "behavior": "creates an order from a valid cart", "layer": "unit", "x": -Infinity }
# @intent: { "entity": NaN, "action": "create", "behavior": "creates an order from a valid cart", "layer": "unit" }
# @intent: { "a": "\ud800" }
# @intent: { "a": "\ud800\ud800" }
# @intent: { "entity": "Order", "action": "create", "behavior": "creates an order from a valid cart", "layer": "unit", "x": [[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]] }
