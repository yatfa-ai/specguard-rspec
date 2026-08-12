# frozen_string_literal: true

# The four edge-case lines in the valid fixture, plus the bare-word rule.
#
# These are the cases a `gsub`-then-`JSON.parse` normalizer gets WRONG. They are
# pinned individually — rather than only via the corpus counts — so a regression
# names the specific behavior it broke instead of just moving a total from 7
# to 6.
#
# The second group in this file (`the default output path`) pins something
# else entirely, and shares the file for the reason both groups exist: they are
# regression targets, held to the byte, for behaviour that has already been
# ratified elsewhere and must not move by accident.
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

# SPGD-305's HARD CONSTRAINT, pinned rather than trusted: without `--json`,
# stdout, stderr and the exit code are byte-identical to what `70ea201` — the
# commit before the second renderer existed — produced.
#
# Why a byte lock and not "the flag defaults to false, so it is inert"
# ====================================================================
# Adding `--json` did not only add a branch. It moved the leading
# `checked N spec file(s)` line inside a conditional in `CLI#report_selection`,
# and it replaced `CLI#report_results`'s body with a partition shared by two
# renderers. Both edits are on the default path, and both are the kind that
# drifts by a space or a newline without any example noticing: the existing
# suite asserts with `include`, which is blind to a line's position, to a line
# appearing twice, and to anything gained around it.
#
# The lock is also not only this file's business.
# `spec/specguard/rspec/validator_backend_spec.rb` replays a recorded
# `validate-intent --source --json` report through this CLI over the same two
# relative paths and compares the whole of stdout — `expect(go_stdout).to
# eq(ruby_stdout)`, no extraction and no normalisation — plus stderr apart from
# the one line naming the validator, plus the exit code. The `checked …` lines
# below are INSIDE that comparison rather than stripped from it, so a drift in
# either one diffs there too. This file locks the same strings without needing a
# report to compare against, which is what makes it the half that still fails if
# the recordings are ever regenerated from a drifted binary.
#
# The three runs cover every shape the default renderer can print: the summary
# line alone, a FAIL block with schema reasons AND one with a `problem`, and the
# unread-file clause with its line-less FAIL. Paths are RELATIVE, so the
# expected bytes are stable; the first example fails loudly if the suite is not
# running from the gem root, without which the rest would be comparing piles of
# read failures.
RSpec.describe "the default output path, byte for byte" do
  def run(*paths)
    stdout = StringIO.new
    stderr = StringIO.new
    code = SpecGuard::RSpec::CLI.new(stdout: stdout, stderr: stderr, env: {}).run(paths)
    [stdout.string, stderr.string, code]
  end

  # The one line every run writes to stderr since SPGD-247. It is part of the
  # default path and so it is pinned here too, not normalised away.
  PROVENANCE = "specguard-lint: validated in Ruby (SPECGUARD_VALIDATE_INTENT is unset)\n"

  it "is running where the relative fixture paths resolve" do
    expect(%w[spec/fixtures/order_spec.rb spec/fixtures/broken_intent_spec.rb])
      .to all(satisfy { |path| File.file?(path) })
  end

  it "prints exactly this for a clean file" do
    stdout, stderr, code = run("spec/fixtures/order_spec.rb")

    expect(stdout).to eq(<<~OUT)
      specguard-lint: checked 1 spec file
      specguard-lint: checked 7 @intent annotations, 0 malformed
    OUT
    expect(stderr).to eq(PROVENANCE)
    expect(code).to eq(0)
  end

  it "prints exactly this for the malformed corpus" do
    stdout, stderr, code = run("spec/fixtures/order_spec.rb", "spec/fixtures/broken_intent_spec.rb")

    expect(stdout).to eq(<<~OUT)
      specguard-lint: checked 2 spec files
      FAIL  spec/fixtures/broken_intent_spec.rb:9
              -> <root>: missing required property 'entity'
              -> <root>: additional property 'entiity' is not allowed
      FAIL  spec/fixtures/broken_intent_spec.rb:15
              -> layer: value 'model' is not one of ['unit', 'integration', 'request', 'system']
      FAIL  spec/fixtures/broken_intent_spec.rb:21
              -> <root>: missing required property 'layer'
              -> behavior: string is 4 char(s), minLength is 15
      FAIL  spec/fixtures/broken_intent_spec.rb:28 — unterminated object literal (an annotation must fit on one line)
      FAIL  spec/fixtures/broken_intent_spec.rb:34 — no '{...}' object literal follows the @intent: token
      specguard-lint: checked 12 @intent annotations, 5 malformed
    OUT
    expect(stderr).to eq(PROVENANCE)
    expect(code).to eq(1)
  end

  it "prints exactly this for a file it could not read" do
    stdout, stderr, code = run("spec/fixtures/gone_spec.rb")

    expect(stdout).to eq(<<~OUT)
      specguard-lint: checked 1 spec file
      FAIL  spec/fixtures/gone_spec.rb — could not read file: No such file or directory @ rb_sysopen - spec/fixtures/gone_spec.rb
      specguard-lint: checked 0 @intent annotations, 0 malformed; 1 file could not be read
    OUT
    expect(stderr).to eq(PROVENANCE)
    expect(code).to eq(1)
  end
end
