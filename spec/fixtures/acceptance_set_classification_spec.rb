# The SECOND surviving divergence, and the one that moves the CLASSIFICATION
# rather than the verdict.
#
# PROTOCOL.md §1.1(c) refuses any container nested deeper than 100. Ruby's
# `JSON.parse` checks `max_nesting` when it is about to read a VALUE, so a
# container sitting at depth 101 with NOTHING IN IT is never checked and is
# accepted. One level, and only while the deepest container is empty — put a
# value in it and Ruby refuses too. The boundary is pinned from both sides in
# spec/specguard/rspec/validator_backend_spec.rb.
#
# So a payload at exactly depth 101 with an empty innermost array:
#
#   Ruby path   parses it, then the SCHEMA refuses it   -> "kind": "schema"
#   binary      refuses it as a parse failure           -> "kind": "parse"
#
# BOTH FAIL, and both exit 1 — this is not a verdict difference. What differs
# is the reason each gives, and `kind` is the field a machine consumer reads
# to route a finding. That makes it worth pinning even though no run changes
# colour over it.
#
# It can only ever be this shape. A container is not a value the schema
# permits — every value under `additionalProperties: false` is a string or an
# array of strings (schemas/open-test-intent.v1.json) — so a payload deep
# enough to diverge is a payload the schema refuses, which is exactly why the
# gem lands on `schema` and never on a pass. The nesting class therefore
# cannot move a verdict, only a classification; the surrogate class is the one
# that moves a verdict, in acceptance_set_verdict_spec.rb.
#
# The first annotation is valid on purpose: a file of nothing but failures
# would compare two reports that agree only about what broke.
#
# See spec/fixtures/validator/acceptance-set-classification.json for this
# file's recorded report.

# @intent: { "entity": "Order", "action": "create", "behavior": "creates an order from a valid cart", "layer": "unit" }
# @intent: { "entity": "Order", "action": "create", "behavior": "creates an order from a valid cart", "layer": "unit", "preconditions": [[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]] }
