# The acceptance-set difference, shape (vi): CPython's `json` accepts a payload
# that Ruby's `JSON.parse` rejects, and the payload IS schema-valid.
#
# This is the strongest divergence between the two backends and the only one
# where the EXIT CODE moves. The Ruby path cannot parse the payload, so it
# reports one malformed annotation and exits 1. The backend parses it, validates
# it, finds nothing wrong, and exits 0. Only the file agrees; the finding, the
# counts and the exit code do not.
#
# Reachable through exactly ONE of the acceptance set's three members, and that
# is provable rather than observed: a schema-valid payload has to put the
# offending syntax inside a value the schema permits, and every value the schema
# permits is a string or an array of strings (schemas/open-test-intent.v1.json).
# A non-finite literal is a number and a deep nest is a container, so neither can
# ever occupy a schema-legal slot — they are always shape (v). A surrogate escape
# lives inside a string, so it can.
#
# The last two annotations are the BOUNDARY, and they are here to keep the rule
# from being read as wider than it is: a lone LOW surrogate and a well-formed
# surrogate pair are accepted by BOTH parsers, so they pass on both backends.
# Ruby rejects a high surrogate that is not followed by a low one — not every
# surrogate escape.
#
# See spec/fixtures/validator/acceptance-set-verdict.json for this file's
# recorded report, and `Scanner#parse` for the ratification.

# @intent: { "entity": "\ud800Or", "action": "create", "behavior": "creates an order from a valid cart", "layer": "unit" }
# @intent: { "entity": "\ud800\ud800Or", "action": "create", "behavior": "creates an order from a valid cart", "layer": "unit" }
# @intent: { "entity": "\udc00Or", "action": "create", "behavior": "creates an order from a valid cart", "layer": "unit" }
# @intent: { "entity": "\ud83d\ude00Or", "action": "create", "behavior": "creates an order from a valid cart", "layer": "unit" }
