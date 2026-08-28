# frozen_string_literal: true

require "tmpdir"
require "fileutils"
require "open3"

RSpec.describe SpecGuard::RSpec::CLI do
  subject(:cli) { described_class.new(stdout: stdout, stderr: stderr) }

  let(:stdout) { StringIO.new }
  let(:stderr) { StringIO.new }

  def out = stdout.string
  def err = stderr.string

  # The exit contract itself lives in spec/specguard/rspec/exit_contract_spec.rb.
  # What is left here is the CLI's *reporting*: which stream each kind of
  # message goes to, and whether it tells the truth about what was checked.
  #
  # NOTE for anyone diffing against slice 1: findings moved from stderr to
  # stdout when validation landed. They are the tool's product, they are where
  # the reference validator puts them, and lint findings conventionally go
  # there. Diagnostics *about the linter* — the empty-selection warning, misuse,
  # a schema that would not load — stay on stderr, and the exit code rather
  # than the stream is now the machine-readable signal.
  describe "honest reporting of what was checked" do
    # "checked 12 files, found no annotations" must never be confusable with
    # "checked 0 files". Reporting the count is what makes them distinguishable.
    it "states how many files it checked" do
      cli.run([fixture_path("order_spec.rb")])

      expect(out).to include("checked 1 spec file")
    end

    it "warns loudly on stderr when the selection is empty" do
      Dir.mktmpdir do |dir|
        Dir.chdir(dir) { cli.run([]) }
      end

      expect(err).to include("warning", "selected 0 spec files")
    end

    it "does not put the empty-selection warning on stdout, where it could be piped away" do
      Dir.mktmpdir { |dir| Dir.chdir(dir) { cli.run([]) } }

      expect(out).not_to include("warning")
    end

    it "reports a misuse on stderr rather than crashing" do
      Dir.mktmpdir do |dir|
        Dir.chdir(dir) { cli.run(["--changed"]) }
      end

      expect(err).to include("--changed requires a git repository")
    end

    it "summarises how many annotations it checked and how many failed" do
      cli.run([fixture_path("broken_intent_spec.rb")])

      expect(out).to include("checked 5 @intent annotations, 5 malformed")
    end

    # An annotation-free run states its zero explicitly. Silence would be
    # indistinguishable from "the linter never ran".
    it "states the zero when a checked file carries no annotations" do
      Dir.mktmpdir do |dir|
        path = File.join(dir, "bare_spec.rb")
        File.write(path, "RSpec.describe(Order) { it('works') {} }\n")
        cli.run([path])
      end

      expect(out).to include("checked 0 @intent annotations, 0 malformed")
    end

    it "prints each malformed annotation at its own file:line" do
      cli.run([fixture_path("broken_intent_spec.rb")])

      expect(out).to include(":28 — unterminated object literal")
      expect(out).to include(":34 — no '{...}' object literal")
    end

    it "prints nothing per-annotation when every annotation is valid" do
      cli.run([fixture_path("order_spec.rb")])

      expect(out).not_to include("FAIL")
      expect(out).to include("checked 7 @intent annotations, 0 malformed")
    end

    # The end of the false green. A malformed `@intent:` followed on the same
    # line by a well-formed one used to have its neighbour's payload attributed
    # to it, so the whole run reported "checked 1 @intent annotation, 0
    # malformed" and exited 0 — the gate reporting success having checked
    # nothing that was actually wrong. Asserted through the CLI because the
    # exit code is what a CI job reads; the scanner-level assertions live in
    # annotation_scanner_spec.rb.
    #
    # The neighbour payload must be schema-**valid** for this example to pin
    # anything. With an incomplete one the adopted payload fails validation on
    # its own missing properties, so the run already exits non-zero before the
    # fix and both the exit-code and "1 malformed" assertions hold either way —
    # green for a reason that has nothing to do with the bound. Measured on
    # this fixture: pre-fix "0 malformed", exit 0; post-fix "1 malformed",
    # exit 1. All three assertions below discriminate.
    it "fails the run on a malformed annotation that is followed by a well-formed one" do
      code = Dir.mktmpdir do |dir|
        path = File.join(dir, "adopted_payload_spec.rb")
        File.write(path, %(# @intent: (entity: Order) - superseded by @intent: ) +
                         %({ entity: "Order", action: "checkout", ) +
                         %(behavior: "returns 402 payment required on expired card", ) +
                         %(layer: "request" }\n))
        cli.run([path])
      end

      expect(code).to eq(SpecGuard::RSpec::CLI::EXIT_MALFORMED)
      expect(out).to include("checked 1 @intent annotation, 1 malformed")
      expect(out).to include("no '{...}' object literal")
    end
  end

  describe "options" do
    it "prints the version" do
      expect(cli.run(["--version"])).to eq(0)
      expect(out).to include("specguard-rspec #{SpecGuard::RSpec::VERSION}")
    end

    it "prints usage" do
      cli.run(["--help"])

      expect(out).to include("Usage: specguard-lint")
    end

    it "does not scan anything when only printing the version" do
      cli.run(["--version"])

      expect(out).not_to include("checked")
    end

    # `--require-validator` asserts that the Go backend produced this run's
    # verdicts; the contract lives in validator_backend_spec.rb. What belongs
    # here is the two things about it that are OptionParser's business.
    describe "--require-validator" do
      # The reason this is a flag rather than a second environment variable,
      # and the reason that choice is the point of the feature rather than a
      # style call. `SPECGUARD_VALIDATE_INTENT_REQURED=1` is silently no
      # assertion at all — the very bug the flag exists to catch, reproduced one
      # level up. A mistyped flag cannot fail open.
      it "cannot be mistyped into a silently unasserted run" do
        expect(cli.run(["--requre-validator"])).to eq(SpecGuard::RSpec::CLI::EXIT_MISUSE)
        expect(err).to include("specguard-lint: error: ")
        expect(out).not_to include("checked")
      end

      # The flag asserts something about a RUN, and neither of these is one:
      # parse_options returns nil and #run is done before the backend is ever
      # resolved. Asserted with the variable unset, which is exactly the
      # configuration that makes a real run exit 2.
      it "leaves --help and --version exiting 0" do
        expect(described_class.new(stdout: stdout, stderr: stderr, env: {})
                 .run(["--require-validator", "--help"])).to eq(SpecGuard::RSpec::CLI::EXIT_OK)
        expect(described_class.new(stdout: stdout, stderr: stderr, env: {})
                 .run(["--require-validator", "--version"])).to eq(SpecGuard::RSpec::CLI::EXIT_OK)
        expect(err).to be_empty
      end

      it "documents itself in the usage text" do
        cli.run(["--help"])

        expect(out).to include("--require-validator")
      end
    end
  end

  # `--json` is the second renderer over the same Array<Linter::Result> the text
  # report is built from (SPGD-305). What is asserted here is what a CONSUMER
  # depends on: that stdout is one document and nothing else, that every field
  # the Result carries survives — `kind` above all, the field the prose renderer
  # destroys — and that `errors` is always a list so nobody has to branch on its
  # type. The exit-code half of the contract lives in exit_contract_spec.rb, and
  # the proof that the default path did not move lives in
  # regression_targets_spec.rb.
  describe "--json" do
    def run_json(*argv)
      cli.run(["--json", *argv])
      JSON.parse(out)
    end

    def findings_for(*argv) = run_json(*argv).fetch("findings")

    it "emits exactly one JSON document on stdout" do
      run_json(fixture_path("broken_intent_spec.rb"))

      expect { JSON.parse(out) }.not_to raise_error
      expect(out.scan(/^\{$/).length).to eq(1)
    end

    # The prose renderer's whole output has to LEAVE, not be joined by a
    # document. A consumer piping stdout into a parser gets a syntax error the
    # moment either survives.
    it "puts none of the human report on stdout" do
      run_json(fixture_path("broken_intent_spec.rb"))

      expect(out).not_to include("FAIL")
      expect(out).not_to include("malformed")
    end

    # There are TWO `checked …` lines, not one — a leading spec-file count from
    # #report_selection and a trailing annotation count from #summary_line. The
    # open-test-intent's own linter warns that handling only
    # the trailing one is the trap here, so both are asserted gone.
    it "removes BOTH `checked ...` lines, the leading one as well as the trailing" do
      run_json(fixture_path("order_spec.rb"))

      expect(out).not_to include("checked")
    end

    # Neither line is LOST, though: the leading count becomes summary.files and
    # the trailing one summary.annotations, computed once by the CLI and handed
    # to whichever renderer runs. A document that quietly dropped them would let
    # "checked nothing" read as "all clean" — in structured form.
    it "carries both counts into the document instead of dropping them" do
      report = run_json(fixture_path("order_spec.rb"), fixture_path("broken_intent_spec.rb"))

      expect(report["summary"]).to eq("files" => 2, "annotations" => 12, "failed" => 5)
    end

    it "names the protocol it validated against, and the mode the port calls this" do
      report = run_json(fixture_path("order_spec.rb"))

      expect(report["schema"]).to eq("open-test-intent.v1.json")
      expect(report["mode"]).to eq("source")
    end

    # The document must not be able to name a schema the gem does not carry.
    it "declares the schema it actually vendors" do
      expect(SpecGuard::RSpec::JSONReporter::SCHEMA_ID)
        .to eq(File.basename(SpecGuard::RSpec::SCHEMA_PATH))
    end

    describe "every Linter::Result field survives the renderer" do
      # The four kinds, each reached the way a user reaches it. `kind` is
      # carried precisely because "a failed extraction and an unparseable
      # payload both land in `problem`, which makes the two indistinguishable
      # downstream once flattened to prose" (Finding) — so a renderer that
      # dropped it would leave the document no better than the prose.
      def kinds_in(dir)
        File.write(File.join(dir, "extraction_spec.rb"), "# @intent:\n")
        File.write(File.join(dir, "parse_spec.rb"), "# @intent: {layer: request}\n")
        File.write(File.join(dir, "schema_spec.rb"),
                   %(# @intent: { entity: "Order", action: "total", behavior: "sums", layer: "unit" }\n))
        %w[extraction_spec.rb parse_spec.rb schema_spec.rb].map { |name| File.join(dir, name) } +
          [File.join(dir, "gone_spec.rb")]
      end

      it "sets `kind` on a finding of each of the four kinds" do
        Dir.mktmpdir do |dir|
          findings = findings_for(*kinds_in(dir))

          expect(findings.map { |finding| finding["kind"] })
            .to eq(%w[extraction parse schema read])
        end
      end

      # `:0` is not somewhere a reader can go. The text renderer already drops
      # it (Linter::Result#location); the document has to drop it too, or every
      # CI annotation and editor quickfix built on this points at a line that
      # does not exist.
      it "gives a read failure a null line rather than the 0 sentinel" do
        Dir.mktmpdir do |dir|
          finding = findings_for(File.join(dir, "gone_spec.rb")).first

          expect(finding["line"]).to be_nil
          expect(finding).to include("ok" => false, "kind" => "read")
        end
      end

      it "keeps the line number on findings that have one" do
        finding = findings_for(fixture_path("broken_intent_spec.rb")).first

        expect(finding["line"]).to eq(9)
      end

      it "echoes the file path back exactly as it was given" do
        Dir.mktmpdir do |dir|
          path = File.join(dir, "gone_spec.rb")

          expect(findings_for(path).first["file"]).to eq(path)
        end
      end

      it "reports a passing annotation as a finding with no kind" do
        finding = findings_for(fixture_path("order_spec.rb")).first

        expect(finding).to include("ok" => true, "kind" => nil, "errors" => [])
      end
    end

    # report.go:23-26 is explicit that a consumer must never have to branch on
    # the type of `errors`. The gem's Result keeps `problem` (one sentence) and
    # `reasons` (a list) mutually exclusive, so this is the one place the two
    # collapse — and the collapse must not leak either shape.
    describe "`errors` is always a list of strings" do
      it "carries every schema reason, not the first" do
        errors = findings_for(fixture_path("broken_intent_spec.rb")).first["errors"]

        expect(errors).to eq([
                               "<root>: missing required property 'entity'",
                               "<root>: additional property 'entiity' is not allowed"
                             ])
      end

      it "wraps a single `problem` sentence in a list rather than emitting a bare string" do
        Dir.mktmpdir do |dir|
          path = File.join(dir, "typo_spec.rb")
          File.write(path, "# @intent:\n")

          expect(findings_for(path).first["errors"])
            .to eq(["no '{...}' object literal follows the @intent: token"])
        end
      end

      it "is an empty list, never null, on a passing finding" do
        findings = findings_for(fixture_path("order_spec.rb"))

        expect(findings.map { |finding| finding["errors"] }).to all(eq([]))
      end
    end

    # README.md:65-67 claims this document is "key-, type- and value-identical"
    # to `validate-intent --source --json`. The port grew an `intent` key
    # (SPGD-340) carrying WHAT THE PAYLOAD PARSED TO, so this renderer has to
    # grow it too or that claim quietly stops being true — and it would stop
    # being true in the direction nobody notices, since a consumer reading the
    # port's document and then this one finds a key missing rather than wrong.
    describe "`intent` — what the payload parsed to" do
      it "carries the parsed annotation on a passing finding" do
        finding = findings_for(fixture_path("order_spec.rb")).first

        expect(finding["intent"]).to include(
          "entity" => "Order", "action" => "checkout", "layer" => "request"
        )
      end

      # Same rule as the port's: `ok` says whether it is good, `intent` says
      # what it is, and a schema-rejected annotation still says something.
      it "carries it on a schema-rejected finding too" do
        finding = findings_for(fixture_path("broken_intent_spec.rb")).first

        expect(finding["ok"]).to be(false)
        expect(finding["kind"]).to eq("schema")
        expect(finding["intent"]).to be_a(Hash)
      end

      it "is null, and present, where there was no payload" do
        Dir.mktmpdir do |dir|
          path = File.join(dir, "typo_spec.rb")
          File.write(path, "# @intent:\n")
          finding = findings_for(path).first

          expect(finding).to have_key("intent")
          expect(finding["intent"]).to be_nil
        end
      end

      # Key ORDER, not just presence: the claim is key-for-key with a document
      # whose order is positional, and Ruby preserves insertion order, so this
      # is assertable rather than merely hoped for.
      it "is the last key, matching the port's order" do
        finding = findings_for(fixture_path("order_spec.rb")).first

        expect(finding.keys).to eq(%w[file line ok kind errors intent])
      end
    end

    describe "the document's own consistency" do
      # `ok` is derived from the exit code the text path would also have
      # produced rather than recomputed from the findings, following
      # report.go:84-89, so the two renderers cannot disagree about the verdict.
      it "mirrors the exit code in `ok`" do
        expect(cli.run(["--json", fixture_path("order_spec.rb")])).to eq(0)
        expect(JSON.parse(out)["ok"]).to be(true)
      end

      it "reports ok: false for the run that exits 1" do
        expect(cli.run(["--json", fixture_path("broken_intent_spec.rb")])).to eq(1)
        expect(JSON.parse(out)["ok"]).to be(false)
      end

      # summary.failed counts every failing FINDING — read failures included,
      # as the port's Emit does — so it always equals the number of entries a
      # consumer would find with "ok" => false. It is deliberately NOT the text
      # summary's "M malformed", which excludes unread files and reports them in
      # its own clause.
      it "makes summary.failed equal the number of failing findings" do
        Dir.mktmpdir do |dir|
          report = run_json(fixture_path("broken_intent_spec.rb"), File.join(dir, "gone_spec.rb"))

          expect(report.dig("summary", "failed"))
            .to eq(report["findings"].count { |finding| finding["ok"] == false })
          expect(report.dig("summary", "failed")).to eq(6)
        end
      end

      # An unreadable file contributed no annotation site, in the document for
      # the same reason it gets its own clause in the text summary: counting it
      # would report annotations that were never read.
      it "does not count an unread file as an annotation site" do
        Dir.mktmpdir do |dir|
          report = run_json(File.join(dir, "a_spec.rb"), File.join(dir, "b_spec.rb"))

          expect(report["summary"]).to eq("files" => 2, "annotations" => 0, "failed" => 2)
        end
      end
    end

    # Diagnostics about the linter itself do not move: the SPGD-247 provenance
    # line and every warning stay on stderr, byte for byte. A document on stdout
    # is a report about the CODE, not a reason to relocate the commentary.
    describe "stderr is untouched" do
      it "still writes exactly one provenance line naming the implementation" do
        described_class.new(stdout: stdout, stderr: stderr, env: {}).run(["--json", fixture_path("order_spec.rb")])

        expect(err).to eq("specguard-lint: validated in Ruby (SPECGUARD_VALIDATE_INTENT is unset)\n")
      end

      it "still warns loudly about an empty selection" do
        Dir.mktmpdir { |dir| Dir.chdir(dir) { cli.run(["--json"]) } }

        expect(err).to include("warning", "selected 0 spec files")
      end

      # A run that selected nothing still owes stdout a document — a consumer
      # parsing stdout must not get an empty string, which is the one thing it
      # cannot tell apart from a crash.
      it "still emits a document when nothing was selected" do
        Dir.mktmpdir { |dir| Dir.chdir(dir) { cli.run(["--json"]) } }

        expect(JSON.parse(out))
          .to include("ok" => true, "findings" => [],
                      "summary" => { "files" => 0, "annotations" => 0, "failed" => 0 })
      end
    end

    # DECISION (SPGD-305, recorded rather than defaulted into): no exit-2 path
    # emits a document. Those runs produced no verdicts, and a document is a
    # report about what was checked — `{"ok": false, "findings": []}` for a run
    # that checked nothing is this project's signature vacuous-green shape with
    # a schema wrapped round it. The prose goes to stderr, where diagnostics
    # about the linter already live, and the exit code says the rest.
    describe "a run that could not produce verdicts emits no document" do
      it "says nothing on stdout when the flags are misused" do
        expect(cli.run(["--json", "--changed", fixture_path("order_spec.rb")])).to eq(2)

        expect(out).to be_empty
        expect(err).to include("specguard-lint: error: --changed cannot be combined with explicit files")
      end

      # `--json --require-validator` with the variable unset. Both flags are
      # about the run rather than the report, and the failure is prose on
      # stderr exactly as it is without `--json`.
      it "reports an unmet --require-validator as prose on stderr, not as a document" do
        code = described_class.new(stdout: stdout, stderr: stderr, env: {})
                              .run(["--json", "--require-validator", fixture_path("order_spec.rb")])

        expect(code).to eq(SpecGuard::RSpec::CLI::EXIT_MISUSE)
        expect(out).to be_empty
        expect(err).to include("specguard-lint: error: --require-validator was given")
      end

      it "says nothing on stdout when the schema will not load" do
        stub_const("SpecGuard::RSpec::SCHEMA_PATH", "/nonexistent/open-test-intent.v1.json")

        expect(cli.run(["--json", fixture_path("order_spec.rb")])).to eq(2)
        expect(out).to be_empty
      end
    end

    it "documents itself in the usage text" do
      cli.run(["--help"])

      expect(out).to include("--json")
    end
  end

  describe "reading files" do
    it "reports an unreadable file rather than aborting the whole run" do
      Dir.mktmpdir do |dir|
        missing = File.join(dir, "gone_spec.rb")

        expect { cli.run([missing]) }.not_to raise_error
        expect(out).to include("could not read file")
      end
    end

    # A read failure is not line-scoped — no line of the file was ever seen —
    # and slice 1 carries `line: 0` as the sentinel for that. Printing it as
    # `file:0` leaks the sentinel into the product: `:0` is not somewhere a
    # reader can go, and anything parsing `file:line` (CI annotations, editor
    # quickfix, review comments) would point at a line that does not exist.
    # The binary drops the line for exactly these findings (`JSONFinding`,
    # open-test-intent, cmd/validate-intent/report.go: "`line` is null where a
    # finding is not line-scoped"), and this is the one output shape the suite
    # did not pin to the byte, which is how `:0` shipped.
    it "names the file WITHOUT a line number, which it does not have" do
      Dir.mktmpdir do |dir|
        missing = File.join(dir, "gone_spec.rb")
        cli.run([missing])

        expect(out).to include("FAIL  #{missing} — could not read file")
        expect(out).not_to include("#{missing}:0")
      end
    end

    it "keeps the line number for findings that DO have one" do
      cli.run([fixture_path("broken_intent_spec.rb")])

      expect(out).to match(/^FAIL  \S+broken_intent_spec\.rb:9$/)
    end

    # Slice 1 classified an unreadable file as KIND_EXTRACTION, which under the
    # exit contract would read as a claim about an annotation. It is now
    # KIND_READ — the validator's own name for it — so the decision to
    # nonetheless fail the run (reference parity: `FAIL ... — could not read
    # file`, exit 1) is visible and reversible in one place.
    it "classifies it as a read failure, not as a malformed annotation" do
      Dir.mktmpdir do |dir|
        finding = SpecGuard::RSpec::Scanner.scan_file(File.join(dir, "gone_spec.rb")).first

        expect(finding.kind).to eq(SpecGuard::RSpec::Finding::KIND_READ)
      end
    end

    # The summary count exists to keep the totals honest, so it must not
    # overstate what was inspected. A file that could not be opened contributed
    # no annotation: counting its Result as one turns "12 files, none of them
    # read" into "checked 12 @intent annotations, 12 malformed".
    it "does not count an unread file as an annotation it checked" do
      Dir.mktmpdir do |dir|
        cli.run([File.join(dir, "a_spec.rb"), File.join(dir, "b_spec.rb")])

        expect(out).to include("checked 0 @intent annotations, 0 malformed; 2 files could not be read")
      end
    end

    it "still counts the annotations it did check alongside the unread file" do
      Dir.mktmpdir do |dir|
        cli.run([fixture_path("broken_intent_spec.rb"), File.join(dir, "gone_spec.rb")])

        expect(out).to include("checked 5 @intent annotations, 5 malformed; 1 file could not be read")
      end
    end

    it "does not let invalid UTF-8 reach the shell as an exception" do
      Dir.mktmpdir do |dir|
        path = File.join(dir, "bad_spec.rb")
        File.binwrite(path, "# @intent: {entity:\"Order\"}\n# \xff\xfe\n")

        expect { cli.run([path]) }.not_to raise_error
        expect(out).to include("invalid UTF-8 byte sequence")
        expect(out).to include("FAIL  #{path} — could not read file")
      end
    end
  end

  describe "--changed with explicit files" do
    # Honouring the files and dropping --changed without a word is the same
    # class of quiet no-op the slice exists to remove: --changed appears to have
    # been applied when it was not.
    it "refuses the combination rather than silently ignoring --changed" do
      cli.run(["--changed", fixture_path("order_spec.rb")])

      expect(err).to include("--changed cannot be combined with explicit files")
    end

    it "checks nothing when it refuses" do
      cli.run(["--changed", fixture_path("order_spec.rb")])

      expect(out).not_to include("checked")
    end

    it "exits 2, the misuse code, rather than accusing an annotation" do
      expect(cli.run(["--changed", fixture_path("order_spec.rb")])).to eq(2)
    end
  end

  describe "the reason given for an empty --changed selection" do
    # The blocker's real sting: the warning did not just fire on an empty
    # selection, it stated something FALSE — "nothing in the diff matched
    # *_spec.rb" when a spec file demonstrably had changed. A confidently wrong
    # reason is worse than a quiet one, because a human reading it stops
    # looking.
    def git(*args, chdir:)
      _out, e, status = Open3.capture3("git", *args, chdir: chdir)
      raise "git #{args.join(' ')} failed: #{e}" unless status.success?
    end

    def repo_with_nested_spec
      dir = Dir.mktmpdir("specguard-cli")
      git("init", "-q", "--initial-branch=main", chdir: dir)
      git("config", "user.email", "t@example.com", chdir: dir)
      git("config", "user.name", "T", chdir: dir)
      File.write(File.join(dir, "README.md"), "hello\n")
      git("add", "-A", chdir: dir)
      git("commit", "-q", "-m", "base", chdir: dir)
      git("checkout", "-q", "-b", "feature", chdir: dir)
      FileUtils.mkdir_p(File.join(dir, "other/spec"))
      File.write(File.join(dir, "other/spec/sibling_spec.rb"), "# a spec\n")
      git("add", "-A", chdir: dir)
      git("commit", "-q", "-m", "add a spec", chdir: dir)
      FileUtils.mkdir_p(File.join(dir, "sub"))
      yield dir
    ensure
      FileUtils.remove_entry(dir) if dir
    end

    it "does not claim nothing matched when a spec changed elsewhere in the repo" do
      repo_with_nested_spec do |dir|
        Dir.chdir(File.join(dir, "sub")) { cli.run(["--changed"]) }
      end

      expect(err).to include("selected 0 spec files")
      expect(err).not_to include("none matching *_spec.rb")
      expect(err).to include("outside")
    end

    it "says how many changed spec files were excluded for being outside the directory" do
      repo_with_nested_spec do |dir|
        Dir.chdir(File.join(dir, "sub")) { cli.run(["--changed"]) }
      end

      expect(err).to include("1 changed spec file")
    end

    # Two filters emptied this selection, and naming only the first is the
    # exact failure this whole block exists to prevent. "2 changed spec files
    # … but 1 is outside" reads as complete arithmetic: 2 matched, 1 excluded,
    # so the reader concludes the remaining one was checked. It was not. The
    # unreadable file is the reason the run linted nothing, and it has to
    # appear alongside the other cause, not behind it.
    it "names the unreadable files too when both filters emptied the selection" do
      repo_with_nested_spec do |dir|
        # A symlink to a missing target: git tracks it (so it survives
        # `--diff-filter=d` and is counted as a changed spec) but `File.file?`
        # refuses it, which is the `unreadable` branch.
        File.symlink("missing_target.rb", File.join(dir, "sub/broken_spec.rb"))
        git("add", "-A", chdir: dir)
        git("commit", "-q", "-m", "add a broken symlink spec", chdir: dir)

        Dir.chdir(File.join(dir, "sub")) { cli.run(["--changed"]) }
      end

      expect(err).to include("selected 0 spec files")
      # Asserted as one shape rather than three independent `include`s: the
      # point of this example is that the two clauses appear TOGETHER and in
      # order. Separate matchers stay green if a refactor split them onto
      # their own lines, reversed them, or repeated a count — which is
      # precisely the regression this example exists to catch.
      expect(err).to match(
        /2 changed spec files against \S+, but 1 is outside \S+ \(--changed selects only files under the current directory\) and 1 could not be read/
      )
    end
  end
end
