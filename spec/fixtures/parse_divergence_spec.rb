# A corpus for the ONE difference between the two backends that is not a read
# failure: a payload that survives normalisation and still is not JSON.
#
# PayloadNormalizer's job is to make PROTOCOL.md §1's permissive syntax parse —
# single quotes, bare-word KEYS, trailing commas. It succeeds on all of those,
# and a payload it rescues renders identically on both backends. What it cannot
# rescue is a bare-word VALUE or a key that is not a key at all, and those are
# the only inputs that reach `JSON.parse` still broken. Both backends then
# report KIND_PARSE, on the same line, under the same
# `could not parse annotation: ` prefix, with the same counts and the same exit
# code — and a different tail, because the Ruby path interpolates Ruby's
# `JSON::ParserError#message` and the binary carries its own.
#
# See `Scanner#parse` for the ratification, and
# spec/fixtures/validator/parse-divergence.json for this file's recorded report.
#
# The first annotation is valid on purpose: a file of nothing but failures
# would compare two reports that agree only about what broke.

# @intent: { entity: "Order", action: "create", behavior: "creates an order from a valid cart", layer: "unit" }
# @intent: { "entity": "Order", "action": "create", "behavior": "rejects an order missing a customer", "layer": unit }
# @intent: {bad_key}
