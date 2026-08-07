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

    it "maps a parse finding onto `problem`" do
      result = only_result(file: "a_spec.rb", line: 4, ok: false, kind: "parse",
                           errors: ["could not parse annotation: unexpected token"])

      expect(result.problem).to eq("could not parse annotation: unexpected token")
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
