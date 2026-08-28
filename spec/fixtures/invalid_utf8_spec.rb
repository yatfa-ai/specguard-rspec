# A corpus for the read failure whose REASON TEXT differs between the two
# backends: a file that is not well-formed UTF-8.
#
# PROTOCOL.md §1.1 makes UTF-8 part of what a JSON text IS, so neither side
# repairs the bytes and neither substitutes U+FFFD and carries on. Both refuse
# the FILE — same classification, same `could not read file: ` prefix, no line
# number, exit 1 — and both name the CONDITION rather than an offset. Only the
# tail differs: `Scanner#scan_text` says `invalid UTF-8 byte sequence`, the
# binary says `input is not well-formed UTF-8 (PROTOCOL.md §1.1 requires it)`.
#
# See `Scanner#scan_text` for the ratification, and
# spec/fixtures/validator/utf8-divergence.json for this file's recorded report.
#
# The annotation below is VALID on purpose. Both backends must refuse the file
# without ever reaching it, so this file contributes no annotation sites to the
# count the two sides compare — every annotation in that count belongs to the
# clean file named beside this one. A file that could not be read is not a file
# that was checked and found clean.

# @intent: { entity: "Order", action: "create", behavior: "creates an order from a valid cart", layer: "unit" }

# The invalid byte follows. 0xFF is not a legal UTF-8 lead byte in any
# position, so this line cannot be read as text under any encoding assumption
# the linter is allowed to make:
# ��
