# frozen_string_literal: true

require "tmpdir"
require "fileutils"
require "json"

# The opt-in Go validator backend.
#
# WHAT THIS FILE IS NOT — the same disclaimer message_parity_spec.rb carries,
# for the same reason. Nothing here runs `validate-intent`. Every document
# below is either RECORDED from the real binary (spec/fixtures/validator/) or
# hand-built to be a shape the real binary must never emit, and the "binary" is
# a four-line shell stub this file writes into a tmpdir.
#
# That is deliberate, not a shortcut. `lib/specguard/rspec.rb`'s SCHEMA_PATH
# forbids this gem a cross-repo runtime dependency, and a spec that shelled out
# to a Go binary would pass on one container and be unrunnable on every other.
# The live cross-repo comparison — gem-with-Go-backend vs gem-with-Ruby-backend
# over a shared corpus — belongs in open-test-intent's
# tests/parity/run_ruby_parity.sh, section "the Go backend", and it is there.
#
# What IS proven here, without leaving the gem:
#
#   * the argument vector, including the glob escaping (a path is a path, and
#     must not be re-expanded as a pattern by a tool whose arguments are globs);
#   * the JSON -> Linter::Result mapping, including the `problem`/`reasons`
#     split the document flattens away and `kind` is the only way back to;
#   * that a recorded document renders BYTE FOR BYTE what the Ruby path renders
#     for the same corpus — the ticket's first success criterion, asserted
#     rather than assumed;
#   * that the one residual difference in an ANNOTATION-level message — the
#     parse-failure tail, Ruby's `JSON::ParserError` against the port's
#     CPython-shaped diagnostic — is enumerated and asserted from BOTH sides,
#     so closing it fails this file rather than leaving a stale claim;
#   * that every way the backend can fail is exit 2 and never exit 1.
RSpec.describe SpecGuard::RSpec::ValidatorBackend do
  subject(:backend) { described_class }

  let(:tmpdir) { @tmpdir }

  around do |example|
    Dir.mktmpdir("specguard-validator") do |dir|
      @tmpdir = dir
      example.run
    end
  end

  # A stand-in for `validate-intent`: it records the argument vector it was
  # given, prints a canned stdout/stderr, and exits with a canned code. Written
  # as /bin/sh with the payloads in separate files so nothing here has to be
  # quoted into a script.
  def stub_validator(stdout: "", stderr: "", exit_code: 0, name: "validate-intent-stub")
    out_file = File.join(tmpdir, "#{name}.out")
    err_file = File.join(tmpdir, "#{name}.err")
    File.write(out_file, stdout)
    File.write(err_file, stderr)

    path = File.join(tmpdir, name)
    File.write(path, <<~SH)
      #!/bin/sh
      printf '%s\\n' "$@" >> #{args_log(name)}
      echo >> #{args_log(name)}
      cat #{out_file}
      cat #{err_file} >&2
      exit #{exit_code}
    SH
    FileUtils.chmod(0o755, path)
    path
  end

  def args_log(name = "validate-intent-stub")
    File.join(tmpdir, "#{name}.args")
  end

  # Every invocation's argument vector, one array per invocation.
  def recorded_invocations(name = "validate-intent-stub")
    return [] unless File.exist?(args_log(name))

    File.read(args_log(name)).split("\n\n", -1).reject(&:empty?).map { |block| block.split("\n") }
  end

  # A minimal well-formed `--source --json` document.
  def document(findings, annotations: nil, mode: "source")
    annotations ||= findings.count { |f| !%w[read no-match].include?(f[:kind]) }
    JSON.generate(
      schema: "open-test-intent.v1.json",
      mode: mode,
      ok: findings.all? { |f| f[:ok] },
      summary: { files: 1, annotations: annotations, failed: findings.count { |f| !f[:ok] } },
      findings: findings.map do |f|
        { file: f[:file], line: f[:line], ok: f[:ok], kind: f[:kind], errors: f[:errors] || [] }
      end
    )
  end

  def ok_finding(file: "a_spec.rb", line: 1)
    { file: file, line: line, ok: true, kind: nil, errors: [] }
  end

  def run_backend(paths, **stub)
    described_class.resolve(env: { described_class::ENV_VAR => stub_validator(**stub) }).check(paths)
  end

  # ------------------------------------------------------------------------ #
  describe ".resolve" do
    # The default, and the only configuration any existing user has. It is
    # asserted first because the whole slice rests on it: an unset variable
    # must not merely behave like the Ruby path, it must BE the Ruby path.
    it "is nil when the variable is unset" do
      expect(described_class.resolve(env: {})).to be_nil
    end

    # `SPECGUARD_VALIDATE_INTENT=` in a CI environment file is somebody turning
    # the backend off, not asking for a binary named "". Follows the
    # blank-means-unset idiom Configuration already uses.
    it "is nil when the variable is blank" do
      expect(described_class.resolve(env: { described_class::ENV_VAR => "" })).to be_nil
    end

    it "is nil when the variable is only whitespace" do
      expect(described_class.resolve(env: { described_class::ENV_VAR => "   " })).to be_nil
    end

    it "returns a runner for an executable binary" do
      path = stub_validator
      runner = described_class.resolve(env: { described_class::ENV_VAR => path })

      expect(runner).to be_a(described_class::Runner)
      expect(runner.path).to eq(path)
    end

    it "strips surrounding whitespace off the path" do
      path = stub_validator
      runner = described_class.resolve(env: { described_class::ENV_VAR => "  #{path}  " })

      expect(runner.path).to eq(path)
    end

    # Failing here rather than at the first invocation is what keeps "the
    # validator you asked for is not there" from surfacing as a run that
    # selected files, checked none of them, and printed a summary.
    it "raises rather than returning an unusable runner when the binary is missing" do
      expect { described_class.resolve(env: { described_class::ENV_VAR => File.join(tmpdir, "nope") }) }
        .to raise_error(SpecGuard::RSpec::ValidatorError, /does not exist/)
    end

    it "raises when the path is a directory" do
      expect { described_class.resolve(env: { described_class::ENV_VAR => tmpdir }) }
        .to raise_error(SpecGuard::RSpec::ValidatorError, /is not a file/)
    end

    it "raises when the binary is not executable" do
      path = File.join(tmpdir, "not-executable")
      File.write(path, "#!/bin/sh\n")
      FileUtils.chmod(0o644, path)

      expect { described_class.resolve(env: { described_class::ENV_VAR => path }) }
        .to raise_error(SpecGuard::RSpec::ValidatorError, /is not executable/)
    end

    it "names the variable in its diagnostics, so the fix is obvious" do
      expect { described_class.resolve(env: { described_class::ENV_VAR => File.join(tmpdir, "nope") }) }
        .to raise_error(SpecGuard::RSpec::ValidatorError, /SPECGUARD_VALIDATE_INTENT/)
    end

    # A bare command name is refused rather than resolved against PATH: which
    # binary a CI job validated against must not depend on what else is
    # installed. The refusal has to carry the fix, though — "validate-intent
    # does not exist" is a baffling thing to read about a program that is right
    # there on your PATH.
    it "refuses a bare command name and says how to turn it into a path" do
      expect { described_class.resolve(env: { described_class::ENV_VAR => "validate-intent" }) }
        .to raise_error(SpecGuard::RSpec::ValidatorError, /takes a path, not a command name/)
    end

    it "does not offer that hint when it was given a path" do
      expect { described_class.resolve(env: { described_class::ENV_VAR => File.join(tmpdir, "nope") }) }
        .to raise_error(SpecGuard::RSpec::ValidatorError, /\Athe validator backend at .* does not exist\z/)
    end
  end

  # ------------------------------------------------------------------------ #
  # The gem's arguments are PATHS; `validate-intent`'s are GLOB PATTERNS. Handed
  # through unescaped, `spec/fixtures/bracket[1]_spec.rb` would be read as a
  # character class and `weird*_spec.rb` as a wildcard that can match OTHER
  # files — a linter checking something nobody named, or nothing at all.
  describe ".escape_glob" do
    it "leaves an ordinary path untouched" do
      expect(described_class.escape_glob("spec/fixtures/order_spec.rb"))
        .to eq("spec/fixtures/order_spec.rb")
    end

    it "escapes a star" do
      expect(described_class.escape_glob("star*_spec.rb")).to eq("star[*]_spec.rb")
    end

    it "escapes a question mark" do
      expect(described_class.escape_glob("q?_spec.rb")).to eq("q[?]_spec.rb")
    end

    # Only the opening bracket. A `]` outside a class is already a literal, and
    # CPython's glob.escape does not touch it either — this is a port of that
    # function, not an independent idea about escaping.
    it "escapes an opening bracket and leaves the closing one alone" do
      expect(described_class.escape_glob("bracket[1]_spec.rb")).to eq("bracket[[]1]_spec.rb")
    end

    it "escapes an unclosed bracket" do
      expect(described_class.escape_glob("bracket[unclosed_spec.rb")).to eq("bracket[[]unclosed_spec.rb")
    end

    # `**` is the port's recursive glob. Escaped it is two literal stars, which
    # is what a file actually called `**_spec.rb` deserves.
    it "escapes a recursive-glob component into literal stars" do
      expect(described_class.escape_glob("a/**/b_spec.rb")).to eq("a/[*][*]/b_spec.rb")
    end

    it "does not escape a backslash, which Python's fnmatch treats as a literal" do
      expect(described_class.escape_glob('back\\slash_spec.rb')).to eq('back\\slash_spec.rb')
    end
  end

  # ------------------------------------------------------------------------ #
  describe "the argument vector" do
    it "invokes the binary with --source --json and the given paths" do
      run_backend(["a_spec.rb", "b_spec.rb"],
                  stdout: document([ok_finding(file: "a_spec.rb"), ok_finding(file: "b_spec.rb")]))

      expect(recorded_invocations).to eq([%w[--source --json a_spec.rb b_spec.rb]])
    end

    it "escapes every path it passes" do
      run_backend(["bracket[1]_spec.rb"], stdout: document([ok_finding(file: "bracket[1]_spec.rb")]))

      expect(recorded_invocations.first).to eq(["--source", "--json", "bracket[[]1]_spec.rb"])
    end

    # `validate-intent --source` with no FILE argument is a usage error (exit
    # 2). An empty selection is not misuse of the linter — CLI#report_selection
    # has already warned about it — so there is nothing to ask.
    it "does not invoke the binary at all for an empty selection" do
      runner = described_class.resolve(env: { described_class::ENV_VAR => stub_validator })

      expect(runner.check([])).to eq([])
      expect(recorded_invocations).to be_empty
    end

    it "passes a path containing a space as one argument, with no shell in between" do
      run_backend(["a dir/a_spec.rb"], stdout: document([ok_finding(file: "a dir/a_spec.rb")]))

      expect(recorded_invocations.first).to eq(["--source", "--json", "a dir/a_spec.rb"])
    end

    # `specguard-lint a_spec.rb a_spec.rb` reports every annotation twice on the
    # Ruby path — Scanner checks the files it is handed, in the order it is
    # handed them — and the port does the same. Deriving the argument vector
    # from a Hash keyed by the escaped pattern collapses the repeat and halves
    # the report, which looks exactly like a clean run on a smaller corpus.
    it "does not de-duplicate a path named twice" do
      run_backend(%w[a_spec.rb a_spec.rb],
                  stdout: document([ok_finding(file: "a_spec.rb"), ok_finding(file: "a_spec.rb")]))

      expect(recorded_invocations.first).to eq(["--source", "--json", "a_spec.rb", "a_spec.rb"])
    end
  end

  # ------------------------------------------------------------------------ #
  # A full audit passes every spec file in the repository, and execve refuses an
  # argument vector past E2BIG. The batching that fixes it must stay invisible:
  # one list back, in argument order.
  describe "batching a large selection" do
    let(:paths) { Array.new(2_500) { |i| format("spec/models/example_%05d_spec.rb", i) } }

    before do
      findings = paths.map { |path| ok_finding(file: path) }
      # The stub answers every batch with the SAME document, which is enough to
      # prove the batching and the concatenation; the per-batch document
      # contents are the mapping's business, asserted above and below.
      @results = run_backend(paths, stdout: document(findings))
    end

    it "splits the run into more than one invocation" do
      expect(recorded_invocations.length).to be > 1
    end

    it "never exceeds the per-invocation file cap" do
      expect(recorded_invocations.map { |args| args.length - 2 })
        .to all(be <= SpecGuard::RSpec::ValidatorBackend::Runner::MAX_BATCH_FILES)
    end

    it "keeps every invocation's argument bytes under the execve budget" do
      expect(recorded_invocations.map { |args| args.sum { |a| a.bytesize + 1 } })
        .to all(be <= SpecGuard::RSpec::ValidatorBackend::Runner::MAX_ARG_BYTES + 32)
    end

    it "passes every path exactly once, in order, across the batches" do
      expect(recorded_invocations.flat_map { |args| args.drop(2) }).to eq(paths)
    end

    it "concatenates the batches' findings into one list" do
      expect(@results.length).to eq(paths.length * recorded_invocations.length)
    end

    # A single path longer than the whole byte budget must still be checked.
    # Dropping it would be the silent omission this project keeps naming.
    it "gives an over-long path a batch of its own rather than dropping it" do
      giant = "spec/#{'x' * (SpecGuard::RSpec::ValidatorBackend::Runner::MAX_ARG_BYTES + 10)}_spec.rb"
      run_backend([giant], stdout: document([ok_finding(file: giant)]), name: "giant")

      expect(recorded_invocations("giant").flat_map { |args| args.drop(2) }).to eq([giant])
    end
  end

  # ------------------------------------------------------------------------ #
  # The document normalizes `problem` and `errors` into one `errors` list and
  # says so in a comment; Linter::Result keeps them apart and CLI#report_failure
  # renders them differently. `kind` is the only way back.
  describe "the JSON -> Linter::Result mapping" do
    def only_result(finding)
      run_backend(["a_spec.rb"], stdout: document([finding])).first
    end

    it "maps a passing finding to a passing result" do
      result = only_result(ok_finding(file: "a_spec.rb", line: 12))

      expect(result).to be_ok
      expect(result.file).to eq("a_spec.rb")
      expect(result.line).to eq(12)
      expect(result.kind).to be_nil
    end

    it "maps a schema finding onto `reasons`, so each one gets its own -> line" do
      result = only_result(file: "a_spec.rb", line: 9, ok: false, kind: "schema",
                           errors: ["<root>: missing required property 'entity'",
                                    "<root>: additional property 'entiity' is not allowed"])

      expect(result.reasons).to eq(["<root>: missing required property 'entity'",
                                    "<root>: additional property 'entiity' is not allowed"])
      expect(result.problem).to be_nil
      expect(result.kind).to eq(SpecGuard::RSpec::Finding::KIND_SCHEMA)
    end

    it "maps an extraction finding onto `problem`, so it renders on one em-dashed line" do
      result = only_result(file: "a_spec.rb", line: 28, ok: false, kind: "extraction",
                           errors: ["unterminated object literal (an annotation must fit on one line)"])

      expect(result.problem).to eq("unterminated object literal (an annotation must fit on one line)")
      expect(result.reasons).to be_empty
      expect(result.kind).to eq(SpecGuard::RSpec::Finding::KIND_EXTRACTION)
    end

    # The wording here is RECORDED, not invented, and that distinction has
    # already cost this file once: it previously read `could not parse
    # annotation: unexpected token` — a string spelled the way RUBY spells it,
    # which the port cannot emit. That spelling is what hid the parse-text
    # divergence between the two backends until it was found by hand. Anything
    # asserted about a `parse` message must come from the binary; see
    # "the parse-failure text is the port's, not Ruby's" below.
    it "maps a parse finding onto `problem`" do
      result = only_result(file: "a_spec.rb", line: 4, ok: false, kind: "parse",
                           errors: ["could not parse annotation: Expecting property name enclosed " \
                                    "in double quotes: line 1 column 2 (char 1)"])

      expect(result.problem).to eq("could not parse annotation: Expecting property name enclosed " \
                                   "in double quotes: line 1 column 2 (char 1)")
      expect(result.kind).to eq(SpecGuard::RSpec::Finding::KIND_PARSE)
    end

    # `line: null` is the document's way of saying "not line-scoped", which is
    # the same rule Result#location applies from the other side.
    it "maps a read finding onto KIND_READ and drops the line from its location" do
      result = only_result(file: "a_spec.rb", line: nil, ok: false, kind: "read",
                           errors: ["could not read file: boom"])

      expect(result.kind).to eq(SpecGuard::RSpec::Finding::KIND_READ)
      expect(result.location).to eq("a_spec.rb")
      expect(result.problem).to eq("could not read file: boom")
    end

    it "preserves finding order" do
      results = run_backend(["a_spec.rb"], stdout: document([
                                                              ok_finding(file: "a_spec.rb", line: 1),
                                                              { file: "a_spec.rb", line: 2, ok: false,
                                                                kind: "schema", errors: ["x"] },
                                                              ok_finding(file: "a_spec.rb", line: 3)
                                                            ]))

      expect(results.map(&:line)).to eq([1, 2, 3])
    end
  end

  # ------------------------------------------------------------------------ #
  # `no-match` is the port's kind for an argument that matched no file. The gem
  # has no Finding::KIND_* for it because the gem has no patterns — its
  # arguments are paths — so it folds into KIND_READ, which is what it means
  # here: a named path that could not be opened.
  describe "a path that matched nothing (`no-match`)" do
    def no_match_result(path)
      escaped = described_class.escape_glob(path)
      run_backend([path], stdout: document([{ file: escaped, line: nil, ok: false, kind: "no-match",
                                              errors: ["no file(s) match #{escaped}"] }])).first
    end

    it "classifies it as a read failure, exactly as the Ruby path does" do
      expect(no_match_result("spec/nope_spec.rb").kind).to eq(SpecGuard::RSpec::Finding::KIND_READ)
    end

    it "is a failed result, so the run still exits 1" do
      expect(no_match_result("spec/nope_spec.rb")).to be_failed
    end

    it "drops the line, so nothing points a reader at a line that does not exist" do
      expect(no_match_result("spec/nope_spec.rb").location).to eq("spec/nope_spec.rb")
    end

    # ENUMERATED DIFFERENCE 1 of 2. The escaped pattern is an artifact of this
    # file; reporting it would misname what the caller asked for. `[[]1]` is
    # not a path anyone typed.
    it "reports the path the caller named, not the escaped pattern" do
      expect(no_match_result("bracket[1]_spec.rb").file).to eq("bracket[1]_spec.rb")
    end

    # ENUMERATED DIFFERENCE 1 of 2, the text half. Go says "no file(s) match
    # <pattern>" — a statement about a glob, which specguard-lint does not
    # have, and which would carry the escaped spelling into the report. The
    # Ruby path says "could not read file: No such file or directory @
    # rb_sysopen - <path>". Same prefix, same classification, same exit code;
    # only the tail differs, and it differs because the backend cannot know the
    # errno.
    it "uses the gem's own wording, sharing the Ruby path's `could not read file: ` prefix" do
      expect(no_match_result("spec/nope_spec.rb").problem)
        .to eq("could not read file: no file at this path")
    end

    it "does not claim an errno it cannot know" do
      expect(no_match_result("spec/nope_spec.rb").problem).not_to include("rb_sysopen")
    end
  end

  # ------------------------------------------------------------------------ #
  # Every one of these is "the linter could not do its job". The contract has
  # already spent exit 1 on "an annotation is malformed" (see CLI), so none of
  # them may reach it — and none may be quietly absorbed either.
  describe "documents the port must never emit" do
    it "refuses output that is not JSON" do
      expect { run_backend(["a_spec.rb"], stdout: "not json at all\n") }
        .to raise_error(SpecGuard::RSpec::ValidatorError, /did not emit a JSON document/)
    end

    it "refuses an empty stdout" do
      expect { run_backend(["a_spec.rb"], stdout: "") }
        .to raise_error(SpecGuard::RSpec::ValidatorError, /did not emit a JSON document/)
    end

    it "refuses a JSON document that is not an object" do
      expect { run_backend(["a_spec.rb"], stdout: "[]\n") }
        .to raise_error(SpecGuard::RSpec::ValidatorError, /where a JSON object was expected/)
    end

    # If the argument vector ever stops saying `--source`, the document says so
    # first — and a report read under the wrong mode's rules is worse than no
    # report.
    it "refuses a document announcing another mode" do
      expect { run_backend(["a_spec.rb"], stdout: document([ok_finding], mode: "adopter")) }
        .to raise_error(SpecGuard::RSpec::ValidatorError, /reported mode "adopter"/)
    end

    it "refuses a document with no findings array" do
      expect { run_backend(["a_spec.rb"], stdout: '{"mode":"source","summary":{"annotations":0}}') }
        .to raise_error(SpecGuard::RSpec::ValidatorError, /no `findings` array/)
    end

    it "refuses a findings entry that is not an object" do
      expect { run_backend(["a_spec.rb"], stdout: '{"mode":"source","summary":{"annotations":0},"findings":["x"]}') }
        .to raise_error(SpecGuard::RSpec::ValidatorError, /not a JSON object/)
    end

    it "refuses a document with no integer annotation count" do
      expect { run_backend(["a_spec.rb"], stdout: '{"mode":"source","summary":{},"findings":[]}') }
        .to raise_error(SpecGuard::RSpec::ValidatorError, /no integer `summary.annotations`/)
    end

    # `summary.annotations` and the findings list are two independent statements
    # about the same run. Output truncated by a full pipe would otherwise show
    # up as a SMALLER clean report — the shape nobody notices.
    it "refuses a document whose annotation count disagrees with its findings" do
      expect { run_backend(["a_spec.rb"], stdout: document([ok_finding], annotations: 7)) }
        .to raise_error(SpecGuard::RSpec::ValidatorError, /reported 7 annotation\(s\) but emitted 1/)
    end

    # A kind this file has not been taught would be rendered under whichever
    # branch of #report_failure it fell into by accident.
    it "refuses a kind it does not know" do
      expect do
        run_backend(["a_spec.rb"],
                    stdout: document([{ file: "a_spec.rb", line: 1, ok: false,
                                        kind: "cosmic-ray", errors: ["boom"] }]))
      end.to raise_error(SpecGuard::RSpec::ValidatorError, /unknown kind "cosmic-ray"/)
    end

    # The `problem` kinds render as ONE em-dashed line. Joining several errors
    # into it would silently print one line where the tool meant several.
    it "refuses more than one error on an extraction finding rather than joining them" do
      expect do
        run_backend(["a_spec.rb"],
                    stdout: document([{ file: "a_spec.rb", line: 1, ok: false,
                                        kind: "extraction", errors: %w[one two] }]))
      end.to raise_error(SpecGuard::RSpec::ValidatorError, /emitted 2 errors on a extraction finding/)
    end

    it "refuses more than one error on a read finding" do
      expect do
        run_backend(["a_spec.rb"],
                    stdout: document([{ file: "a_spec.rb", line: nil, ok: false,
                                        kind: "read", errors: %w[one two] }]))
      end.to raise_error(SpecGuard::RSpec::ValidatorError, /emitted 2 errors on a read finding/)
    end

    it "refuses a failing finding carrying no errors" do
      expect do
        run_backend(["a_spec.rb"],
                    stdout: document([{ file: "a_spec.rb", line: 1, ok: false, kind: "schema", errors: [] }]))
      end.to raise_error(SpecGuard::RSpec::ValidatorError, /with no errors/)
    end

    it "refuses a passing finding carrying a kind" do
      expect do
        run_backend(["a_spec.rb"],
                    stdout: document([{ file: "a_spec.rb", line: 1, ok: true, kind: "schema", errors: [] }]))
      end.to raise_error(SpecGuard::RSpec::ValidatorError, /passing finding/)
    end

    it "refuses a finding with no file" do
      expect do
        run_backend(["a_spec.rb"],
                    stdout: '{"mode":"source","summary":{"annotations":1},' \
                            '"findings":[{"line":1,"ok":true,"kind":null,"errors":[]}]}')
      end.to raise_error(SpecGuard::RSpec::ValidatorError, /no `file`/)
    end

    it "refuses a finding whose errors are not strings" do
      expect do
        run_backend(["a_spec.rb"],
                    stdout: '{"mode":"source","summary":{"annotations":1},' \
                            '"findings":[{"file":"a_spec.rb","line":1,"ok":false,"kind":"schema","errors":[7]}]}')
      end.to raise_error(SpecGuard::RSpec::ValidatorError, /not a list of strings/)
    end

    it "refuses a non-integer line" do
      expect do
        run_backend(["a_spec.rb"],
                    stdout: '{"mode":"source","summary":{"annotations":1},' \
                            '"findings":[{"file":"a_spec.rb","line":"9","ok":true,"kind":null,"errors":[]}]}')
      end.to raise_error(SpecGuard::RSpec::ValidatorError, /non-integer `line`/)
    end
  end

  # ------------------------------------------------------------------------ #
  # 0 and 1 are the port's verdicts. Anything else means it produced none.
  describe "exit codes from the binary" do
    it "accepts 0" do
      expect(run_backend(["a_spec.rb"], stdout: document([ok_finding]), exit_code: 0).length).to eq(1)
    end

    it "accepts 1, which is how it reports a malformed annotation" do
      results = run_backend(["a_spec.rb"],
                            stdout: document([{ file: "a_spec.rb", line: 1, ok: false,
                                                kind: "schema", errors: ["boom"] }]),
                            exit_code: 1)

      expect(results.first).to be_failed
    end

    it "refuses 2 — the port's own 'I could not do my job' code" do
      expect { run_backend(["a_spec.rb"], stdout: "", stderr: "error: could not load schema x\n", exit_code: 2) }
        .to raise_error(SpecGuard::RSpec::ValidatorError, /exited 2/)
    end

    # Without this the operator gets "it exited 2" and nothing to act on, while
    # the binary had already explained itself on the stream nobody forwarded.
    it "quotes the binary's stderr, which is where it explained itself" do
      expect { run_backend(["a_spec.rb"], stdout: "", stderr: "error: could not load schema x\n", exit_code: 2) }
        .to raise_error(SpecGuard::RSpec::ValidatorError, /could not load schema x/)
    end

    it "refuses any other code" do
      expect { run_backend(["a_spec.rb"], stdout: document([ok_finding]), exit_code: 3) }
        .to raise_error(SpecGuard::RSpec::ValidatorError, /exited 3/)
    end

    # A binary deleted or chmod'ed between .resolve and the first batch.
    it "refuses a binary that has stopped being executable since it was resolved" do
      path = stub_validator
      runner = described_class.resolve(env: { described_class::ENV_VAR => path })
      File.delete(path)

      expect { runner.check(["a_spec.rb"]) }
        .to raise_error(SpecGuard::RSpec::ValidatorError, /could not be executed/)
    end
  end

  # ------------------------------------------------------------------------ #
  # THE TICKET'S FIRST SUCCESS CRITERION, asserted here rather than left to the
  # cross-repo harness: with the backend on, `specguard-lint` must produce
  # byte-identical stdout, stderr and exit code across spec/fixtures/.
  #
  # spec/fixtures/validator/source-corpus.json is RECORDED from
  # `validate-intent-go --source --json` over exactly the two paths below —
  # regenerate it with that command, from this directory, if the corpus
  # changes. Recording it is what lets this run anywhere: the assertion is
  # about the gem's mapping, and the binary's job was to produce the document
  # once.
  #
  # The two fixtures are themselves pinned byte-for-byte against
  # open-test-intent's examples/sources/ by run_ruby_parity.sh section 1, so a
  # corpus that drifted out from under this recording fails there.
  describe "a recorded corpus renders exactly what the Ruby path renders" do
    # Relative, and deliberately: both tools echo paths back exactly as given,
    # so the recorded document's `file` values and the Ruby run's have to be
    # spelled the same way. RSpec runs from the gem root.
    let(:paths) { %w[spec/fixtures/order_spec.rb spec/fixtures/broken_intent_spec.rb] }
    let(:recorded) { File.read("spec/fixtures/validator/source-corpus.json") }

    def run_cli(env)
      stdout = StringIO.new
      stderr = StringIO.new
      code = SpecGuard::RSpec::CLI.new(stdout: stdout, stderr: stderr, env: env).run(paths)
      [stdout.string, stderr.string, code]
    end

    # If this fails, the suite is not running from the gem root and every
    # comparison below would be comparing two piles of read failures.
    it "is running where the recorded paths resolve" do
      expect(paths).to all(satisfy { |path| File.file?(path) })
    end

    it "prints the same stdout, byte for byte" do
      ruby_stdout, = run_cli({})
      go_stdout, = run_cli({ described_class::ENV_VAR => stub_validator(stdout: recorded, exit_code: 1) })

      expect(go_stdout).to eq(ruby_stdout)
    end

    # Both must be silent on stderr. A backend that explained itself there
    # would be a difference the stdout comparison cannot see.
    it "prints the same stderr, byte for byte" do
      _, ruby_stderr, = run_cli({})
      _, go_stderr, = run_cli({ described_class::ENV_VAR => stub_validator(stdout: recorded, exit_code: 1) })

      expect(go_stderr).to eq(ruby_stderr)
      expect(go_stderr).to be_empty
    end

    it "exits with the same code" do
      *, ruby_code = run_cli({})
      *, go_code = run_cli({ described_class::ENV_VAR => stub_validator(stdout: recorded, exit_code: 1) })

      expect(go_code).to eq(ruby_code)
      expect(go_code).to eq(SpecGuard::RSpec::CLI::EXIT_MALFORMED)
    end

    # Non-vacuity, in the shape run_ruby_parity.sh's header argues for at
    # length: two empty reports compare equal. The corpus has to have said
    # something.
    it "compared a report that actually contains findings" do
      go_stdout, = run_cli({ described_class::ENV_VAR => stub_validator(stdout: recorded, exit_code: 1) })

      expect(go_stdout).to include("checked 12 @intent annotations, 5 malformed")
      expect(go_stdout.lines.count { |line| line.start_with?("FAIL  ") }).to eq(5)
    end
  end

  # ------------------------------------------------------------------------ #
  # THE ONE ENUMERATED DIFFERENCE THAT IS NOT A READ FAILURE.
  #
  # The corpus above is byte-identical on both backends, and that is a true
  # statement about THAT corpus rather than about the linter: its findings are
  # `schema` and `extraction` only. It contains no `parse` finding at all, and
  # a `parse` finding is the one annotation-level shape whose text moves.
  #
  # PayloadNormalizer rescues PROTOCOL.md §1's permissive syntax on both sides,
  # so every hazard that goes THROUGH normalisation successfully compares
  # equal. Only a payload that survives normalisation and still fails
  # `JSON.parse` diverges — the Ruby path interpolates Ruby's
  # `JSON::ParserError#message`, the port reproduces CPython's — and neither
  # the corpus above nor the gem's hazard fixtures contained one.
  #
  # So it is enumerated here, in the two-sided shape run_ruby_parity.sh uses
  # for its ratifications: the shared half is asserted, AND the texts are
  # asserted to still differ, so making them converge fails this file and
  # forces the entry to be retired rather than left to rot.
  #
  # spec/fixtures/validator/parse-divergence.json is RECORDED from
  # `validate-intent-go --source --json spec/fixtures/parse_divergence_spec.rb`,
  # run from the gem root. See `Scanner#parse` for the ratification itself.
  describe "the parse-failure text is the port's, not Ruby's" do
    let(:paths) { %w[spec/fixtures/parse_divergence_spec.rb] }
    let(:recorded) { File.read("spec/fixtures/validator/parse-divergence.json") }

    def run_cli(env)
      stdout = StringIO.new
      stderr = StringIO.new
      code = SpecGuard::RSpec::CLI.new(stdout: stdout, stderr: stderr, env: env).run(paths)
      [stdout.string, stderr.string, code]
    end

    def both_ways
      ruby = run_cli({})
      go = run_cli({ described_class::ENV_VAR => stub_validator(stdout: recorded, exit_code: 1) })
      [ruby, go]
    end

    def fail_lines(stdout)
      stdout.lines.map(&:chomp).select { |line| line.start_with?("FAIL  ") }
    end

    def parse_prefix
      "could not parse annotation: "
    end

    it "is running where the recorded path resolves" do
      expect(paths).to all(satisfy { |path| File.file?(path) })
    end

    # Non-vacuity first: if the fixture stopped producing parse failures, every
    # "they differ" assertion below would pass over an empty list.
    it "compared two parse findings on each side" do
      (ruby_stdout, *), (go_stdout, *) = both_ways

      expect(fail_lines(ruby_stdout).length).to eq(2)
      expect(fail_lines(go_stdout).length).to eq(2)
      expect(fail_lines(go_stdout)).to all(include(parse_prefix))
      expect(fail_lines(ruby_stdout)).to all(include(parse_prefix))
    end

    # The shared half. Same classification, same file, same LINE — unlike a
    # read failure, a parse failure is line-scoped and both backends agree on
    # which annotation broke — and the same prefix.
    it "reports the same annotations, at the same locations, under the same prefix" do
      (ruby_stdout, *), (go_stdout, *) = both_ways

      locations = ->(stdout) { fail_lines(stdout).map { |line| line.split(" — ").first } }

      expect(locations.call(go_stdout)).to eq(locations.call(ruby_stdout))
      expect(locations.call(go_stdout))
        .to eq(["FAIL  spec/fixtures/parse_divergence_spec.rb:21",
                "FAIL  spec/fixtures/parse_divergence_spec.rb:22"])
    end

    # The summary line is where "same classification" stops being a claim about
    # prose: a parse failure counts as an annotation examined AND as malformed,
    # and it must land in the same clause on both sides.
    it "counts them identically, and as annotations rather than unread files" do
      (ruby_stdout, *), (go_stdout, *) = both_ways
      summary = ->(stdout) { stdout.lines.map(&:chomp).grep(/checked \d+ @intent/).first }

      expect(summary.call(go_stdout)).to eq(summary.call(ruby_stdout))
      expect(summary.call(go_stdout)).to eq("specguard-lint: checked 3 @intent annotations, 2 malformed")
    end

    it "exits 1 on both — a divergent message is still a malformed annotation" do
      (*, ruby_code), (*, go_code) = both_ways

      expect(go_code).to eq(ruby_code)
      expect(go_code).to eq(SpecGuard::RSpec::CLI::EXIT_MALFORMED)
    end

    it "says nothing on stderr on either backend" do
      (_, ruby_stderr, *), (_, go_stderr, *) = both_ways

      expect(go_stderr).to eq(ruby_stderr)
      expect(go_stderr).to be_empty
    end

    # The other side of the ratification. If these ever agree, the difference
    # has been closed and this whole describe block should be deleted in favour
    # of adding the fixture to the byte-identical corpus above.
    it "still differs in the tail, and only in the tail" do
      (ruby_stdout, *), (go_stdout, *) = both_ways
      tails = ->(stdout) { fail_lines(stdout).map { |line| line.split(parse_prefix, 2).last } }

      expect(fail_lines(go_stdout)).not_to eq(fail_lines(ruby_stdout))
      tails.call(ruby_stdout).zip(tails.call(go_stdout)).each do |ruby_tail, go_tail|
        expect(ruby_tail).not_to be_empty
        expect(go_tail).not_to be_empty
        expect(go_tail).not_to eq(ruby_tail)
      end
    end

    # And the tails are specifically CPython's, passed through unaltered rather
    # than reworded by the mapping. This is what makes the difference a
    # pass-through the port owns, not a third independent spelling this gem
    # would then have to maintain.
    it "passes the port's CPython-shaped wording through unaltered" do
      (ruby_stdout, *), (go_stdout, *) = both_ways

      expect(go_stdout).to include("could not parse annotation: Expecting value: line 1 column 102 (char 101)")
      expect(go_stdout).to include("could not parse annotation: Expecting property name enclosed " \
                                   "in double quotes: line 1 column 2 (char 1)")
      # Ruby's own spelling, for the same two payloads, on the same two lines.
      expect(ruby_stdout).to include("could not parse annotation: unexpected character: 'unit' at line 1 column 102")
      expect(ruby_stdout).to include("could not parse annotation: expected object key, got 'bad_key}' at line 1 column 2")
    end
  end

  # ------------------------------------------------------------------------ #
  # THE ACCEPTANCE-SET DIFFERENCE — the GENERATOR of divergence, not another
  # instance of one.
  #
  # The block above ratifies a parse-message TAIL. That framing was too narrow,
  # and the way it was too narrow matters more than the fact: it described the
  # symptom (two JSON parsers word an error differently) rather than the cause
  # (two JSON parsers do not accept the same LANGUAGE). Once the cause is
  # named, the divergences it produces are enumerable in one pass instead of
  # being discovered one fixture at a time.
  #
  # The cause: `bin/validate-intent` parses with CPython's `json`, and the port
  # reproduces CPython's grammar deliberately — see
  # cmd/validate-intent/pyjson.go, "WHAT IT BUYS BEYOND THE PROSE", which names
  # the non-finite literals and records that accepting them was the whole point
  # of retiring an earlier exclusion. `Scanner#parse` uses Ruby's `JSON.parse`.
  # CPython's grammar is strictly the more permissive of the two, so there is a
  # set of payloads one accepts and the other refuses, and every member of that
  # set is a divergence.
  #
  # The set was DERIVED, not guessed: 89,108 documents — the port's own
  # `pyjson_fuzz_test.go` seed corpus and token alphabet, a generated
  # well-formed corpus, and every one of the 65,536 single `\uXXXX` escapes —
  # were put through CPython's `json.loads` and Ruby's `JSON.parse`. The
  # difference has exactly THREE members, and widening the sweep did not add a
  # fourth. `Scanner#parse` carries the enumeration and the method.
  #
  # It produces TWO divergence shapes, and only one of them is a wording
  # difference:
  #
  #   (v)  the payload is not schema-valid. The Ruby path never gets a value to
  #        validate, so it reports KIND_PARSE — one em-dash line. The backend
  #        parses it fine and reports KIND_SCHEMA — a `-> ` line per violation.
  #        Same file, same line, same counts, same exit code; different
  #        classification and a completely different block.
  #
  #   (vi) the payload IS schema-valid. The Ruby path reports it malformed and
  #        exits 1; the backend reports NOTHING and exits 0. Only the file
  #        agrees.
  #
  # Both are RATIFIED rather than closed, and the reason is scope rather than
  # taste: this slice's contract is that an unset SPECGUARD_VALIDATE_INTENT
  # changes nothing, and every way to close these changes the DEFAULT path. See
  # `Scanner#parse` for the decision, including the part that is not mine —
  # two of the three members close with `JSON.parse` options that already
  # exist, which makes this a question for whoever owns the gem's default
  # behaviour rather than a limitation.
  describe "the JSON acceptance-set difference" do
    def parses?(doc)
      JSON.parse(doc)
      true
    rescue JSON::ParserError, JSON::NestingError
      false
    end

    # ---------------------------------------------------------------------- #
    # The enumeration, asserted against Ruby rather than described in prose.
    #
    # These examples do not touch the backend. They pin the BOUNDARY of the
    # generator, so the fixtures below are demonstrably a sample of a known set
    # rather than a list of things somebody happened to try — and so a Ruby
    # upgrade that moved any boundary fails here, naming the cause, instead of
    # surfacing later as a mysterious parity break.
    describe "the set has exactly the three enumerated members" do
      # Member 1. CPython accepts all three; the port accepts them on purpose.
      it "refuses the non-finite literals — member 1" do
        expect(parses?('{"a":NaN}')).to be(false)
        expect(parses?('{"a":Infinity}')).to be(false)
        expect(parses?('{"a":-Infinity}')).to be(false)
      end

      # Exhaustive over the escape axis. Every one of the 65,536 single
      # `\uXXXX` escapes, and the answer is a contiguous range: the HIGH
      # surrogates and nothing else. A lone LOW surrogate is accepted by Ruby,
      # which is why the rule is not "surrogate escapes diverge" — stating it
      # that way would be wider than the truth and would make the boundary
      # fixtures below look like failures.
      it "refuses exactly the high surrogates, across all 65536 escapes — member 2" do
        refused = (0x0000..0xFFFF).select do |cp|
          !parses?(format('["\\u%04x"]', cp))
        end

        expect(refused).to eq((0xD800..0xDBFF).to_a)
      end

      # And a high surrogate is rescued only by a LOW one immediately after it.
      it "refuses a high surrogate unless a low surrogate follows it — member 2" do
        expect(parses?('"\\ud800\\udc00"')).to be(true)
        expect(parses?('"\\udbff\\udfff"')).to be(true)
        expect(parses?('"\\ud800\\ud800"')).to be(false)
        expect(parses?('"\\ud800\\u0041"')).to be(false)
        expect(parses?('"\\ud800A"')).to be(false)
        expect(parses?('"\\ud800"')).to be(false)
      end

      # Member 3. Ruby defaults to `max_nesting: 100`; CPython has no
      # document-depth limit short of its recursion limit, and accepts 2000
      # deep without complaint.
      it "refuses nesting past max_nesting: 100 — member 3" do
        # Ruby counts containers that have contents, so the bare-array boundary
        # sits one level deeper than the object one. Both are pinned because
        # either moving is the same news.
        expect(parses?(("[" * 101) + ("]" * 101))).to be(true)
        expect(parses?(("[" * 102) + ("]" * 102))).to be(false)
        expect(parses?(('{"a":' * 100) + "1" + ("}" * 100))).to be(true)
        expect(parses?(('{"a":' * 101) + "1" + ("}" * 101))).to be(false)
      end

      # The part of the decision that is not this slice's to make, pinned so it
      # stays true. Two of the three members are one existing option away; the
      # surrogate member has no option and would need CPython's string decoder
      # ported into the gem — the trade `Scanner.scan_text` and `Scanner#parse`
      # have already declined twice. Nothing here enables these; the gem's
      # `JSON.parse` call is deliberately left at its defaults.
      it "documents that two of the three members close with existing options" do
        expect { JSON.parse('{"a":NaN}', allow_nan: true) }.not_to raise_error
        expect { JSON.parse(("[" * 200) + ("]" * 200), max_nesting: false) }.not_to raise_error
        # No option rescues the third, which is why closing two would leave the
        # set inconsistent rather than closed.
        expect { JSON.parse('"\\ud800"', allow_nan: true, max_nesting: false) }
          .to raise_error(JSON::ParserError)
      end
    end

    # ---------------------------------------------------------------------- #
    # Shape (v). All three members appear, because the point of enumerating a
    # set is to sample all of it: NaN, Infinity, -Infinity, a non-finite in a
    # REQUIRED property (which the backend reports differently again, as a type
    # error rather than an additional property), a lone high surrogate, a bad
    # surrogate pair, and 101-deep nesting.
    #
    # spec/fixtures/validator/acceptance-set-kind.json is RECORDED from
    # `validate-intent-go --source --json spec/fixtures/acceptance_set_kind_spec.rb`
    # run from the gem root.
    describe "shape (v): the payload is not schema-valid — the CLASSIFICATION differs" do
      let(:paths) { %w[spec/fixtures/acceptance_set_kind_spec.rb] }
      let(:recorded) { File.read("spec/fixtures/validator/acceptance-set-kind.json") }

      def run_cli(env)
        stdout = StringIO.new
        stderr = StringIO.new
        code = SpecGuard::RSpec::CLI.new(stdout: stdout, stderr: stderr, env: env).run(paths)
        [stdout.string, stderr.string, code]
      end

      def both_ways
        [run_cli({}), run_cli({ described_class::ENV_VAR => stub_validator(stdout: recorded, exit_code: 1) })]
      end

      def fail_lines(stdout)
        stdout.lines.map(&:chomp).select { |line| line.start_with?("FAIL  ") }
      end

      it "is running where the recorded path resolves" do
        expect(paths).to all(satisfy { |path| File.file?(path) })
      end

      # Non-vacuity, and coverage of the enumeration in one assertion: seven
      # failures means every member of the set reached the report.
      it "compared seven findings from all three members of the set" do
        (ruby_stdout, *), (go_stdout, *) = both_ways

        expect(fail_lines(ruby_stdout).length).to eq(7)
        expect(fail_lines(go_stdout).length).to eq(7)
      end

      # The shared half — and it is a real half. Everything that tells a reader
      # WHICH annotation is broken agrees.
      it "reports the same annotations, at the same lines" do
        (ruby_stdout, *), (go_stdout, *) = both_ways
        lines = ->(stdout) { fail_lines(stdout).map { |line| line[/:(\d+)/, 1].to_i } }

        expect(lines.call(go_stdout)).to eq(lines.call(ruby_stdout))
        expect(lines.call(go_stdout)).to eq([31, 32, 33, 34, 35, 36, 37])
      end

      it "counts them identically, and as annotations rather than unread files" do
        (ruby_stdout, *), (go_stdout, *) = both_ways
        summary = ->(stdout) { stdout.lines.map(&:chomp).grep(/checked \d+ @intent/).first }

        expect(summary.call(go_stdout)).to eq(summary.call(ruby_stdout))
        expect(summary.call(go_stdout)).to eq("specguard-lint: checked 8 @intent annotations, 7 malformed")
      end

      it "exits 1 on both" do
        (*, ruby_code), (*, go_code) = both_ways

        expect(go_code).to eq(ruby_code)
        expect(go_code).to eq(SpecGuard::RSpec::CLI::EXIT_MALFORMED)
      end

      it "says nothing on stderr on either backend" do
        (_, ruby_stderr, *), (_, go_stderr, *) = both_ways

        expect(go_stderr).to eq(ruby_stderr)
        expect(go_stderr).to be_empty
      end

      # The half that is NOT shared, and the reason this needs its own shape
      # rather than being folded into the tail ratification above: the Ruby
      # path renders a `problem` and the backend renders `reasons`, so there is
      # no common prefix to split on and no tail to compare. The classification
      # itself moved.
      it "differs in CLASSIFICATION, not in a trailing tail" do
        (ruby_stdout, *), (go_stdout, *) = both_ways
        parse_prefix = " — could not parse annotation: "

        # Ruby: every failure is a one-line `problem`.
        expect(fail_lines(ruby_stdout)).to all(include(parse_prefix))
        # Backend: not one of them is, and each is followed by `-> ` reasons.
        expect(fail_lines(go_stdout)).to all(satisfy { |line| !line.include?(parse_prefix) })
        # 15 reason lines against 7 em-dash lines: one per additional-property
        # or type violation, and five apiece for the two `{"a": ...}` payloads
        # that miss all four required properties as well.
        expect(go_stdout.lines.count { |line| line.start_with?("        -> ") }).to eq(15)
        expect(ruby_stdout.lines.count { |line| line.start_with?("        -> ") }).to eq(0)
      end

      # The retire branch. If these ever agree, the acceptance sets have been
      # made to match and this block plus its fixture should be deleted in
      # favour of adding the file to the byte-identical corpus above.
      it "still differs — retire this block if it stops" do
        (ruby_stdout, *), (go_stdout, *) = both_ways

        expect(go_stdout).not_to eq(ruby_stdout)
      end

      # Pinned from both sides, so a change to either spelling is visible here
      # rather than only in the cross-repo harness.
      it "renders Ruby's parse errors one way and the port's schema errors the other" do
        (ruby_stdout, *), (go_stdout, *) = both_ways

        expect(ruby_stdout).to include("could not parse annotation: unexpected token 'NaN' at line 1 column 114")
        expect(ruby_stdout).to include("could not parse annotation: unexpected token '-Infinity' at line 1 column 114")
        expect(ruby_stdout).to include("could not parse annotation: incomplete surrogate pair at '\\ud800\"' at line 1 column 9")
        expect(ruby_stdout).to include("could not parse annotation: invalid surrogate pair at '\\ud800\\ud800\"' at line 1 column 9")
        expect(ruby_stdout).to include("could not parse annotation: nesting of 101 is too deep")

        expect(go_stdout).to include("        -> <root>: additional property 'x' is not allowed")
        expect(go_stdout).to include("        -> entity: expected type string, got number")
        expect(go_stdout).to include("        -> <root>: missing required property 'entity'")
      end
    end

    # ---------------------------------------------------------------------- #
    # Shape (vi). The strongest divergence in this file, and the only one that
    # moves the exit code.
    #
    # spec/fixtures/validator/acceptance-set-verdict.json is RECORDED from
    # `validate-intent-go --source --json spec/fixtures/acceptance_set_verdict_spec.rb`
    # run from the gem root. It exits 0 — that is the finding.
    describe "shape (vi): the payload IS schema-valid — the VERDICT differs" do
      let(:paths) { %w[spec/fixtures/acceptance_set_verdict_spec.rb] }
      let(:recorded) { File.read("spec/fixtures/validator/acceptance-set-verdict.json") }

      def run_cli(env)
        stdout = StringIO.new
        stderr = StringIO.new
        code = SpecGuard::RSpec::CLI.new(stdout: stdout, stderr: stderr, env: env).run(paths)
        [stdout.string, stderr.string, code]
      end

      def both_ways
        [run_cli({}), run_cli({ described_class::ENV_VAR => stub_validator(stdout: recorded, exit_code: 0) })]
      end

      def fail_lines(stdout)
        stdout.lines.map(&:chomp).select { |line| line.start_with?("FAIL  ") }
      end

      it "is running where the recorded path resolves" do
        expect(paths).to all(satisfy { |path| File.file?(path) })
      end

      # The whole finding, in one example. This is not a wording difference and
      # not a classification difference: one backend fails the run and the
      # other passes it, on the same bytes.
      it "fails the run on the Ruby path and passes it on the backend" do
        (ruby_stdout, _, ruby_code), (go_stdout, _, go_code) = both_ways

        expect(ruby_code).to eq(SpecGuard::RSpec::CLI::EXIT_MALFORMED)
        expect(go_code).to eq(SpecGuard::RSpec::CLI::EXIT_OK)
        expect(fail_lines(ruby_stdout).length).to eq(2)
        expect(fail_lines(go_stdout)).to be_empty
      end

      it "disagrees about the counts, not only about the findings" do
        (ruby_stdout, *), (go_stdout, *) = both_ways
        summary = ->(stdout) { stdout.lines.map(&:chomp).grep(/checked \d+ @intent/).first }

        expect(summary.call(ruby_stdout)).to eq("specguard-lint: checked 4 @intent annotations, 2 malformed")
        expect(summary.call(go_stdout)).to eq("specguard-lint: checked 4 @intent annotations, 0 malformed")
      end

      # What DOES still agree, so the entry is honest about its shared half
      # rather than claiming there is none: both read the same file and find
      # the same four annotations in it, and neither says anything on stderr.
      it "agrees on the file and on how many annotations are in it" do
        (ruby_stdout, ruby_stderr, *), (go_stdout, go_stderr, *) = both_ways
        selection = ->(stdout) { stdout.lines.first.chomp }

        expect(selection.call(go_stdout)).to eq(selection.call(ruby_stdout))
        expect(selection.call(go_stdout)).to eq("specguard-lint: checked 1 spec file")
        expect(go_stdout).to include("checked 4 @intent annotations")
        expect(ruby_stdout).to include("checked 4 @intent annotations")
        expect(go_stderr).to eq(ruby_stderr)
        expect(go_stderr).to be_empty
      end

      # The boundary, and the reason the fixture carries four annotations
      # rather than two. Lines 29 and 30 are a lone LOW surrogate and a
      # well-formed pair: both parsers accept both, so they pass on BOTH
      # backends. Without them this block would be evidence for a rule far
      # wider than the one that is true.
      it "does not fire for a lone low surrogate or a well-formed pair" do
        (ruby_stdout, *), = both_ways
        broken = fail_lines(ruby_stdout).map { |line| line[/:(\d+)/, 1].to_i }

        expect(broken).to eq([27, 28])
        expect(broken).not_to include(29, 30)
      end

      # The retire branch, in the only form available here: the backend must
      # still be finding nothing. If it ever reports these, the acceptance sets
      # have converged and this block should go.
      it "still differs — retire this block if it stops" do
        (ruby_stdout, *), (go_stdout, *) = both_ways

        expect(go_stdout).not_to eq(ruby_stdout)
        expect(JSON.parse(recorded)["ok"]).to be(true)
        expect(JSON.parse(recorded)["summary"]["failed"]).to eq(0)
      end
    end
  end

  # ------------------------------------------------------------------------ #
  # Exit 1 means "an annotation is malformed" and nothing else. A backend that
  # could not produce a verdict must not borrow it — and must not land on the
  # `internal error:` backstop either, which reads as a bug in the linter
  # rather than a fixable configuration.
  describe "the exit contract, through the CLI" do
    let(:stdout) { StringIO.new }
    let(:stderr) { StringIO.new }

    def run_with(env_value, argv = ["spec/fixtures/order_spec.rb"])
      SpecGuard::RSpec::CLI
        .new(stdout: stdout, stderr: stderr, env: { described_class::ENV_VAR => env_value })
        .run(argv)
    end

    it "exits 2, not 1, when the binary does not exist" do
      expect(run_with(File.join(tmpdir, "nope"))).to eq(SpecGuard::RSpec::CLI::EXIT_MISUSE)
    end

    it "exits 2, not 1, when the binary is not executable" do
      path = File.join(tmpdir, "not-executable")
      File.write(path, "")
      FileUtils.chmod(0o644, path)

      expect(run_with(path)).to eq(SpecGuard::RSpec::CLI::EXIT_MISUSE)
    end

    it "exits 2, not 1, when the binary exits 2" do
      expect(run_with(stub_validator(stderr: "error: could not load schema x\n", exit_code: 2)))
        .to eq(SpecGuard::RSpec::CLI::EXIT_MISUSE)
    end

    it "exits 2, not 1, when the binary emits unparseable output" do
      expect(run_with(stub_validator(stdout: "{ not json", exit_code: 1)))
        .to eq(SpecGuard::RSpec::CLI::EXIT_MISUSE)
    end

    it "exits 2, not 1, when the binary exits non-zero with unparseable output" do
      expect(run_with(stub_validator(stdout: "boom", exit_code: 1)))
        .to eq(SpecGuard::RSpec::CLI::EXIT_MISUSE)
    end

    # The wording matters as much as the code: `internal error:` tells the
    # reader to file a bug against the gem, when the fix is one environment
    # variable away.
    it "reports the failure as `specguard-lint: error:` on stderr" do
      run_with(File.join(tmpdir, "nope"))

      expect(stderr.string).to start_with("specguard-lint: error: ")
      expect(stderr.string).not_to include("internal error")
    end

    it "keeps the diagnostic off stdout, where it could be piped away" do
      run_with(File.join(tmpdir, "nope"))

      expect(stdout.string).not_to include("error")
    end

    # --help must still work with a broken backend configured: it prints and
    # returns before anything is resolved.
    it "still answers --help when the configured binary is missing" do
      expect(run_with(File.join(tmpdir, "nope"), ["--help"])).to eq(SpecGuard::RSpec::CLI::EXIT_OK)
      expect(stdout.string).to include("Usage: specguard-lint")
    end

    # Misuse of the linter is still misuse of the linter, and it is diagnosed
    # before the backend is ever consulted.
    it "still refuses --changed combined with explicit files" do
      code = SpecGuard::RSpec::CLI
             .new(stdout: stdout, stderr: stderr,
                  env: { described_class::ENV_VAR => stub_validator(stdout: document([ok_finding])) })
             .run(["--changed", "spec/fixtures/order_spec.rb"])

      expect(code).to eq(SpecGuard::RSpec::CLI::EXIT_MISUSE)
      expect(stderr.string).to include("--changed cannot be combined with explicit files")
    end
  end
end
