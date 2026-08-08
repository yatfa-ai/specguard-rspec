# The acceptance-set difference, shape (v): CPython's `json` accepts a payload
# that Ruby's `JSON.parse` rejects, and the payload is NOT schema-valid.
#
# Every annotation below is a member of one closed set: the payloads CPython's
# json accepts and Ruby's JSON.parse does not. That set was derived, not
# guessed — see `Scanner#parse` for the enumeration and how it was swept. It has
# exactly three members:
#
#   1. the non-finite literals NaN / Infinity / -Infinity, which CPython accepts
#      and the port accepts on purpose (cmd/validate-intent/pyjson.go, "WHAT IT
#      BUYS BEYOND THE PROSE");
#   2. a HIGH surrogate escape (\ud800-\udbff) not followed by a LOW one;
#   3. container nesting deeper than Ruby's `max_nesting: 100` default.
#
# None of these three can be rescued by PayloadNormalizer, and none of them is a
# tail difference: the Ruby path calls it KIND_PARSE and renders ONE em-dash
# line, while the backend never reaches its JSON parser in an error state at all
# and reports KIND_SCHEMA with a `-> ` line per violation. The classification
# differs, and so does the whole rendered block.
#
# What still agrees, and is asserted: the file, the line, the number of findings,
# the malformed count and the exit code.
#
# See spec/fixtures/validator/acceptance-set-kind.json for this file's recorded
# report, and `Scanner#parse` for the ratification and its reason.
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
