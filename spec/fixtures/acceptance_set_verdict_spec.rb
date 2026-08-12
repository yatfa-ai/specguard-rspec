# The one surviving divergence between the two backends, and the only one that
# moves the EXIT CODE. It runs the other way from the divergence this file used
# to hold.
#
# A LONE LOW SURROGATE escape (`\udc00`-`\udfff`) is accepted by the gem's
# `JSON.parse` and refused by the binary under PROTOCOL.md §1.1(a), which
# requires every surrogate escape to form a pair. So:
#
#   Ruby path   parses it, validates it, finds nothing wrong  -> exit 0
#   binary      refuses it as a parse failure                 -> exit 1
#
# The gem is the more permissive one here. That is the reverse of how this
# divergence used to read, and the reversal is the point: the binary is now held
# to the specification, and the gem's hand-rolled parser is the side that has
# not caught up. It is not fixed here — the gem's own validation logic is slated
# for removal by this roadmap rather than repair — but it is not silent either.
#
# WHY IT MATTERS BEYOND THE VERDICT: what `JSON.parse` returns for `"\udc00"` is
# a String whose `valid_encoding?` is FALSE. It cannot be re-serialised
# (`JSON.generate` raises on it) and it cannot cross the ingest transport. A
# payload the gem calls valid is therefore one it cannot send, which is why
# §1.1(a) refuses it rather than carrying it.
#
# Reachable through the surrogate class ALONE, and that is provable rather than
# observed: a schema-valid payload has to put the offending syntax inside a
# value the schema permits, and every value the schema permits is a string or an
# array of strings (schemas/open-test-intent.v1.json). A non-finite literal is a
# number and a deep nest is a container, so neither can ever occupy a
# schema-legal slot. A surrogate escape lives inside a string, so it can.
#
# The second annotation is the BOUNDARY, and it keeps the rule from being read
# as wider than it is: a well-formed surrogate PAIR is accepted by both, so it
# passes on both backends. It is the reason a run over this file is not simply
# "everything with a backslash-u fails".
#
# See spec/fixtures/validator/acceptance-set-verdict.json for this file's
# recorded report.

# @intent: { "entity": "\udc00Or", "action": "create", "behavior": "creates an order from a valid cart", "layer": "unit" }
# @intent: { "entity": "😀Or", "action": "create", "behavior": "creates an order from a valid cart", "layer": "unit" }
