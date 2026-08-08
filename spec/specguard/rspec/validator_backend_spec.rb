# frozen_string_literal: true

require "tmpdir"
require "fileutils"
require "json"
require "digest"
require "open3"

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

  # The `--version` line the real binary prints, recorded from
  # `cmd/validate-intent/version.go`'s VersionLine format. The stub answers this
  # unless a test asks it not to.
  #
  # It carries the `schema sha256:` token because the real binary has carried
  # one since open-test-intent slice 17, and because leaving it off would put
  # EVERY example in this file — all of which resolve a stub — in the "no digest
  # reported" band. The exit codes would not move, so nothing would fail; the
  # matched band would simply go untested by default, which is the shape of
  # green this project keeps naming.
  #
  # The digest is COMPUTED, from the same file the gem digests at runtime, so
  # this stub agrees with the gem by construction. A literal would be a copy of
  # a hex string drifting independently of the schema it names — the exact
  # defect the code under test exists to catch, re-created in its own spec.
  def stub_identity
    "validate-intent 1.4.0 (go1.22.12 linux/arm64) schema sha256:#{vendored_digest}"
  end

  # The digest of the schema this gem vendors, read the way the gem reads it.
  def vendored_digest
    Digest::SHA256.file(SpecGuard::RSpec::SCHEMA_PATH).hexdigest
  end

  # A `--version` line in the current format carrying somebody else's contract.
  def identity_reporting(digest)
    "validate-intent 1.4.0 (go1.22.12 linux/arm64) schema sha256:#{digest}"
  end

  # A well-formed digest that is not ours. Derived rather than typed so it
  # cannot accidentally become the vendored one.
  def foreign_digest
    Digest::SHA256.hexdigest("some other schema")
  end

  # A stand-in for `validate-intent`: it records the argument vector it was
  # given, prints a canned stdout/stderr, and exits with a canned code. Written
  # as /bin/sh with the payloads in separate files so nothing here has to be
  # quoted into a script.
  #
  # It branches on `--version` because the real binary does, from ANY argv
  # position (`cmd/validate-intent/main.go` loops the whole vector before
  # anything else). A stub that replayed the report document for every argument
  # vector would answer the identity probe with a report — which is not a thing
  # the real binary can do, so a spec built on it would be testing nothing.
  #
  # `version_stdout: ""`/`version_exit: 1` is the PRE-SLICE-6 binary: no
  # `--version` flag at all, so it reads the word as a filename, says "no
  # file(s) match" on stderr and exits 1.
  def stub_validator(stdout: "", stderr: "", exit_code: 0, name: "validate-intent-stub",
                     version_stdout: stub_identity, version_stderr: "", version_exit: 0)
    out_file = File.join(tmpdir, "#{name}.out")
    err_file = File.join(tmpdir, "#{name}.err")
    vout_file = File.join(tmpdir, "#{name}.vout")
    verr_file = File.join(tmpdir, "#{name}.verr")
    File.write(out_file, stdout)
    File.write(err_file, stderr)
    File.write(vout_file, version_stdout.empty? ? "" : "#{version_stdout}\n")
    File.write(verr_file, version_stderr)

    path = File.join(tmpdir, name)
    File.write(path, <<~SH)
      #!/bin/sh
      printf '%s\\n' "$@" >> #{args_log(name)}
      echo >> #{args_log(name)}
      for arg in "$@"; do
        if [ "$arg" = "--version" ]; then
          cat #{vout_file}
          cat #{verr_file} >&2
          exit #{version_exit}
        fi
      done
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
  def all_invocations(name = "validate-intent-stub")
    return [] unless File.exist?(args_log(name))

    File.read(args_log(name)).split("\n\n", -1).reject(&:empty?).map { |block| block.split("\n") }
  end

  # The CHECK invocations — the identity probe is filtered out so that every
  # assertion about the argument vector, the batching and the file order goes on
  # meaning what it meant before the probe existed. Assertions ABOUT the probe
  # use {version_probes}.
  def recorded_invocations(name = "validate-intent-stub")
    all_invocations(name).reject { |args| args.include?("--version") }
  end

  # The identity probe's invocations. Criterion 6 — "at most once per run" — is
  # a statement about the length of this list.
  def version_probes(name = "validate-intent-stub")
    all_invocations(name).select { |args| args.include?("--version") }
  end

  # Every run now prints exactly one line naming the validator that produced its
  # verdicts, and that line is the ONE thing about the two backends' stderr that
  # is supposed to differ. So the cross-backend comparisons below split stderr
  # in two: this is the rest of it, which must still match byte for byte, and
  # {provenance_lines} is the line itself.
  def stderr_beyond_provenance(stderr)
    stderr.lines.reject { |line| line.start_with?("specguard-lint: validated ") }.join
  end

  def provenance_lines(stderr)
    stderr.lines.map(&:chomp).select { |line| line.start_with?("specguard-lint: validated ") }
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

  # A stub whose report is a clean run over `spec/fixtures/order_spec.rb` —
  # the fixture both CLI-level describes below drive the binary with. It lives
  # here beside {stub_validator} and {document} rather than in either of them
  # because it was byte-identical in both: two copies of one fixture builder
  # means a fixture change has to land twice, or the two blocks quietly stop
  # describing the same binary.
  #
  # `paths` and `run_cli` are deliberately NOT lifted with it. Every describe
  # in this file declares its own — seven of them, each with a different
  # fixture list and a different argv shape — so a single inherited pair would
  # be shadowed almost everywhere it appeared and would make the file less
  # readable, not less repetitive. This one is a fixture; those are local
  # plumbing.
  def clean_stub(**stub)
    stub_validator(stdout: document([ok_finding(file: "spec/fixtures/order_spec.rb")]), **stub)
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

    # Both are silent on stderr APART from the one line naming the validator —
    # and that line is the single thing that must NOT match, because it is what
    # tells the two runs apart when nothing else about them does.
    it "prints the same stderr apart from the line naming the validator" do
      _, ruby_stderr, = run_cli({})
      _, go_stderr, = run_cli({ described_class::ENV_VAR => stub_validator(stdout: recorded, exit_code: 1) })

      expect(stderr_beyond_provenance(go_stderr)).to eq(stderr_beyond_provenance(ruby_stderr))
      expect(stderr_beyond_provenance(go_stderr)).to be_empty
      expect(go_stderr).not_to eq(ruby_stderr)
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

    it "says nothing on stderr on either backend beyond the line naming the validator" do
      (_, ruby_stderr, *), (_, go_stderr, *) = both_ways

      expect(stderr_beyond_provenance(go_stderr)).to eq(stderr_beyond_provenance(ruby_stderr))
      expect(stderr_beyond_provenance(go_stderr)).to be_empty
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

      it "says nothing on stderr on either backend beyond the line naming the validator" do
        (_, ruby_stderr, *), (_, go_stderr, *) = both_ways

        expect(stderr_beyond_provenance(go_stderr)).to eq(stderr_beyond_provenance(ruby_stderr))
        expect(stderr_beyond_provenance(go_stderr)).to be_empty
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
      # the same four annotations in it, and neither says anything on stderr
      # beyond the line naming which of them produced the verdicts.
      it "agrees on the file and on how many annotations are in it" do
        (ruby_stdout, ruby_stderr, *), (go_stdout, go_stderr, *) = both_ways
        selection = ->(stdout) { stdout.lines.first.chomp }

        expect(selection.call(go_stdout)).to eq(selection.call(ruby_stdout))
        expect(selection.call(go_stdout)).to eq("specguard-lint: checked 1 spec file")
        expect(go_stdout).to include("checked 4 @intent annotations")
        expect(ruby_stdout).to include("checked 4 @intent annotations")
        expect(stderr_beyond_provenance(go_stderr)).to eq(stderr_beyond_provenance(ruby_stderr))
        expect(stderr_beyond_provenance(go_stderr)).to be_empty
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

  # ------------------------------------------------------------------------ #
  # NAMING THE IMPLEMENTATION THAT PRODUCED THE VERDICTS.
  #
  # Everything above this point establishes that the two backends produce the
  # same bytes for the same corpus. That is the property the slice wanted, and
  # it is also the problem: with the report identical, a run validated by the Go
  # port and a run validated by Linter were indistinguishable from their output,
  # so "which validator did this CI job actually run" had no answer.
  #
  # `validator_backend.rb` had already refused to leave that question open in
  # the two places it can be decided before a binary runs — a named-but-missing
  # binary is a hard exit 2, and a bare command name is refused rather than
  # PATH-resolved, both because "a run that succeeded against a different
  # validator" is undetectable downstream. This closes the same hole for every
  # binary that DOES resolve, and the assertions below are about the four ways
  # that can go wrong:
  #
  #   * saying nothing on the Ruby arm, which would make the line's ABSENCE
  #     ambiguous between "the Ruby path" and "a gem too old to say";
  #   * composing a sentence ABOUT the binary instead of carrying the binary's
  #     own words, which cannot distinguish two builds this gem has never heard
  #     of;
  #   * letting a binary that cannot self-report cost a verdict, or an exit
  #     code, or a byte of stdout;
  #   * reporting "unavailable" by omitting the line — the silent-omission shape
  #     this project keeps naming, which would read exactly like a run nobody
  #     looked at.
  describe "naming the validator that produced the verdicts" do
    let(:paths) { %w[spec/fixtures/order_spec.rb] }

    def run_cli(env, argv = paths)
      stdout = StringIO.new
      stderr = StringIO.new
      code = SpecGuard::RSpec::CLI.new(stdout: stdout, stderr: stderr, env: env).run(argv)
      [stdout.string, stderr.string, code]
    end

    def provenance_of(env, argv = paths)
      _, stderr, = run_cli(env, argv)
      provenance_lines(stderr).first
    end

    # ---------------------------------------------------------------------- #
    # THE PROBE. Once, before selection, and incapable of failing the run.
    describe "the identity probe" do
      it "asks the binary who it is" do
        described_class.resolve(env: { described_class::ENV_VAR => stub_validator })

        expect(version_probes).to eq([["--version"]])
      end

      # Criterion 6, and the reason it is asked in #verify! rather than beside
      # the report: an audit of a large suite runs many batches, and an identity
      # probe per batch would be a per-file cost for a per-run fact.
      it "asks once per run, not once per batch" do
        paths = Array.new(1_500) { |i| format("spec/models/example_%05d_spec.rb", i) }
        run_backend(paths, stdout: document(paths.map { |path| ok_finding(file: path) }))

        expect(recorded_invocations.length).to be > 1
        expect(version_probes.length).to eq(1)
      end

      # Before selection, so the line lands above the empty-selection warnings
      # and a run that dies mid-way still said what was about to validate it.
      it "asks before it asks for any verdict" do
        run_backend(["a_spec.rb"], stdout: document([ok_finding]))

        expect(all_invocations.first).to eq(["--version"])
      end

      # Criterion 3. The identity is the binary's statement, not the gem's, so
      # the gem must not know its format — a build that words it differently is
      # still telling the truth about which build it is.
      it "carries the binary's own line through verbatim" do
        odd = "some-other-validator 9.9.9-rc1+build.7 [experimental]"
        runner = described_class.resolve(
          env: { described_class::ENV_VAR => stub_validator(version_stdout: odd) }
        )

        expect(runner.identity).to eq(odd)
      end

      # Criterion 6's lower half: the probe belongs to verify!, not to
      # construction, so nothing that merely names a Runner costs a process.
      #
      # The second half of this example is what makes the first half mean
      # anything. `version_probes` answers [] for an args log that does not
      # exist yet, which is indistinguishable from a Runner that stayed quiet —
      # so resolving the SAME stub afterwards proves the log is readable and
      # the counter moves. Without it this passes on a broken instrument.
      it "does not invoke the binary at all before it has been resolved" do
        path = stub_validator

        described_class::Runner.new(path)
        expect(version_probes).to be_empty

        described_class.resolve(env: { described_class::ENV_VAR => path })
        expect(version_probes.length).to eq(1)
      end
    end

    # ---------------------------------------------------------------------- #
    # "IDENTITY UNAVAILABLE" IS NOT A FAILURE TO OBTAIN A VERDICT.
    #
    # `--version` arrived in open-test-intent slice 6. An older build reads it
    # as a filename, reports "no file(s) match" on stderr and exits 1 — and it
    # validates perfectly well. Every shape below must therefore leave the
    # findings, the exit code and stdout exactly as they were.
    describe "a binary that cannot report its identity" do
      def unidentified(**extra)
        described_class.resolve(env: { described_class::ENV_VAR => stub_validator(**extra) })
      end

      it "treats a pre-slice-6 binary's `no file(s) match` refusal as unavailable" do
        runner = unidentified(version_stdout: "", version_stderr: "error: no file(s) match '--version'\n",
                              version_exit: 1)

        expect(runner.identity).to be_nil
      end

      it "treats a silent success as unavailable rather than as an empty identity" do
        expect(unidentified(version_stdout: "").identity).to be_nil
      end

      # The one shape check, and it is about the single line the CLI promises
      # per run rather than about the port's format. A `--version` answering
      # with a report document is answering a different question.
      it "refuses an answer that is more than one line" do
        expect(unidentified(version_stdout: "validate-intent 1.4.0\nand another thing").identity).to be_nil
      end

      it "refuses an answer longer than the line budget" do
        giant = "v#{'9' * SpecGuard::RSpec::ValidatorBackend::Runner::IDENTITY_MAX_BYTES}"

        expect(unidentified(version_stdout: giant).identity).to be_nil
      end

      # An escape sequence in a CI log is somebody else's colour scheme at best
      # and a forged extra line at worst.
      it "refuses an answer carrying control characters" do
        expect(unidentified(version_stdout: "validate-intent \e[31m1.4.0\e[0m").identity).to be_nil
      end

      it "refuses an answer that is not valid text" do
        expect(unidentified(version_stdout: "validate-intent \xFF\xFE").identity).to be_nil
      end

      # Regression: `String#strip` raises Encoding::CompatibilityError on an
      # invalid byte sequence, so testing the shape before the encoding turned
      # a binary with an odd `--version` into `internal error:` and an exit 2 —
      # the linter reporting itself broken because it could not read a line it
      # does not need.
      it "does not let an unreadable answer become an internal error" do
        stub = clean_stub(version_stdout: "validate-intent \xFF\xFE")
        stdout, stderr, code = run_cli({ described_class::ENV_VAR => stub })

        expect(code).to eq(SpecGuard::RSpec::CLI::EXIT_OK)
        expect(stderr).not_to include("internal error")
        expect(stdout).to include("specguard-lint: checked 1 @intent annotation, 0 malformed")
      end

      # THE POINT. Not a ValidatorError, not an exit 2 — the "everything that
      # can go wrong here is exit 2" band is for failures to obtain a VERDICT,
      # and this is not one.
      it "still resolves, and still validates" do
        stub = clean_stub(version_stdout: "", version_exit: 1)
        stdout, _stderr, code = run_cli({ described_class::ENV_VAR => stub })

        expect(code).to eq(SpecGuard::RSpec::CLI::EXIT_OK)
        expect(stdout).to include("specguard-lint: checked 1 @intent annotation, 0 malformed")
      end

      # Criterion 4, stated as the comparison that proves it: the ONLY thing
      # that moves is the wording of the provenance line.
      it "produces the same stdout and the same exit code as a binary that can" do
        identified = run_cli({ described_class::ENV_VAR => clean_stub(name: "with-version") })
        anonymous = run_cli({ described_class::ENV_VAR =>
                              clean_stub(name: "without-version", version_stdout: "", version_exit: 1) })

        expect(anonymous[0]).to eq(identified[0])
        expect(anonymous[2]).to eq(identified[2])
      end

      # Criterion 4's other half, and the one that matters most: unavailable is
      # reported IN WORDS. A run that dropped the line instead would look
      # exactly like a run nobody ever taught to print one.
      it "says so in words, and still names the binary it could not identify" do
        stub = clean_stub(version_stdout: "", version_exit: 1)

        expect(provenance_of({ described_class::ENV_VAR => stub }))
          .to eq("specguard-lint: validated by the binary at #{stub} " \
                 "(SPECGUARD_VALIDATE_INTENT), which could not report its identity, " \
                 "so the schema contract it carries could not be checked")
      end

      it "still prints exactly one such line" do
        stub = clean_stub(version_stdout: "", version_exit: 1)
        _, stderr, = run_cli({ described_class::ENV_VAR => stub })

        expect(provenance_lines(stderr).length).to eq(1)
      end
    end

    # ---------------------------------------------------------------------- #
    describe "the line, with the backend active" do
      it "names the binary's own identity and the path it was resolved from" do
        stub = clean_stub

        expect(provenance_of({ described_class::ENV_VAR => stub }))
          .to eq("specguard-lint: validated by #{stub_identity} at #{stub} (SPECGUARD_VALIDATE_INTENT), " \
                 "which reports carrying the schema this gem vendors — the contract it carries, " \
                 "not necessarily the one this run enforced")
      end

      # Criterion 2. The findings and the two `checked …` lines are the product
      # and are pinned byte-for-byte across the backends above; a line about the
      # linter's own configuration must not join them.
      it "goes on stderr, leaving stdout untouched" do
        stdout, = run_cli({ described_class::ENV_VAR => clean_stub })

        expect(stdout).not_to include("validated")
        expect(stdout).not_to include(stub_identity)
      end

      it "prints exactly one such line per run" do
        _, stderr, = run_cli({ described_class::ENV_VAR => clean_stub })

        expect(provenance_lines(stderr).length).to eq(1)
      end

      # Placement, asserted rather than assumed: emitted right after resolution,
      # so it is above the selection warnings and reads as the premise of
      # everything that follows rather than as a footnote to it.
      it "comes before the empty-selection warning" do
        stub = stub_validator
        stderr = nil
        Dir.mktmpdir { |dir| Dir.chdir(dir) { _, stderr, = run_cli({ described_class::ENV_VAR => stub }, []) } }

        expect(stderr.lines.first).to start_with("specguard-lint: validated by ")
        expect(stderr).to include("selected 0 spec files")
      end
    end

    # ---------------------------------------------------------------------- #
    # THE ARM THAT IS EASY TO FORGET. A line that appeared only when the backend
    # was on would make its absence mean either "validated in Ruby" or "a gem
    # from before this line existed" — which is not an answer, and the default
    # configuration is the one nearly every run uses.
    describe "the line, with the backend off" do
      it "states positively that the Ruby path produced the verdicts" do
        expect(provenance_of({}))
          .to eq("specguard-lint: validated in Ruby (SPECGUARD_VALIDATE_INTENT is unset)")
      end

      # Criterion 5. ValidatorBackend.resolve deliberately collapses unset and
      # blank — `SPECGUARD_VALIDATE_INTENT=` in a CI environment file is
      # somebody turning the backend OFF — and returns nil for both, so this
      # distinction cannot come from the backend and is read from the
      # environment. Somebody who set the variable and got the Ruby path anyway
      # needs to see that the VALUE, not the wiring, is why.
      it "distinguishes a blank value from an unset one" do
        expect(provenance_of({ described_class::ENV_VAR => "" }))
          .to eq("specguard-lint: validated in Ruby (SPECGUARD_VALIDATE_INTENT is set but blank, which means off)")
      end

      it "treats a whitespace-only value as blank, matching .resolve" do
        expect(provenance_of({ described_class::ENV_VAR => "   " }))
          .to eq("specguard-lint: validated in Ruby (SPECGUARD_VALIDATE_INTENT is set but blank, which means off)")
      end

      it "prints exactly one such line per run" do
        _, stderr, = run_cli({})

        expect(provenance_lines(stderr).length).to eq(1)
      end

      # Criterion 2 from the other side: the wording of the off arm's line is
      # the only thing that moves between an unset and a blank variable.
      it "leaves stdout and the exit code identical either way" do
        unset = run_cli({})
        blank = run_cli({ described_class::ENV_VAR => "" })

        expect(blank[0]).to eq(unset[0])
        expect(blank[2]).to eq(unset[2])
        expect(blank[1]).not_to eq(unset[1])
      end

      it "goes on stderr, leaving stdout untouched" do
        stdout, = run_cli({})

        expect(stdout).not_to include("validated")
      end
    end

    # ---------------------------------------------------------------------- #
    # Criterion 1 has no exceptions worth having: a run that says nothing about
    # its validator is the state this slice exists to remove, so the sweep is
    # over every arm at once rather than one assertion per arm.
    it "states which implementation validated the run, on every arm" do
      envs = [{},
              { described_class::ENV_VAR => "" },
              { described_class::ENV_VAR => clean_stub(name: "identified") },
              { described_class::ENV_VAR => clean_stub(name: "anonymous", version_stdout: "", version_exit: 1) }]

      lines = envs.map { |env| provenance_of(env) }

      expect(lines).to all(be_a(String))
      expect(lines.uniq.length).to eq(4)
    end
  end

  # ------------------------------------------------------------------------ #
  # THE SCHEMA CONTRACT ACROSS THE SEAM.
  #
  # The section above carries the binary's identity through and renders it. One
  # token in it was never read: `schema sha256:<64-hex>`, the digest of the
  # schema compiled into that binary, which open-test-intent's `SchemaSHA256`
  # added for exactly one reason —
  #
  #   "a gem that vendors schema A can be pointed at a binary built when
  #   canonical was B, and all three guards stay green while the two halves
  #   enforce different contracts."
  #
  # Both of this ecosystem's digest pins are in-repo: `schema_test.go` compares
  # the Go embed to the Go tree, and this repo's `schema_packaging_spec.rb`
  # compares the vendored copy to this repo's pin. Neither crosses the seam,
  # and on the backend path the gem does not even LOAD its vendored schema
  # (`CLI#run` skips it deliberately) — so nothing in either repo could notice
  # a binary enforcing a different contract than the gem beside it vendors.
  #
  # These examples are the crossing. They are written against the three bands
  # the code owes, and the boundary that matters most is the one between the
  # second and third: "I asked and the answer was wrong" is a refusal, "I could
  # not ask" never is.
  describe "the schema contract across the seam" do
    let(:paths) { %w[spec/fixtures/order_spec.rb] }

    def run_cli(env, argv = paths)
      stdout = StringIO.new
      stderr = StringIO.new
      code = SpecGuard::RSpec::CLI.new(stdout: stdout, stderr: stderr, env: env).run(argv)
      [stdout.string, stderr.string, code]
    end

    def provenance_of(env, argv = paths)
      _, stderr, = run_cli(env, argv)
      provenance_lines(stderr).first
    end

    def error_lines(stderr)
      stderr.lines.map(&:chomp).select { |line| line.start_with?("specguard-lint: error: ") }
    end

    def resolve(**stub)
      described_class.resolve(env: { described_class::ENV_VAR => stub_validator(**stub) })
    end

    # ---------------------------------------------------------------------- #
    # BAND (a): reported and equal.
    describe "a binary carrying the schema this gem vendors" do
      it "records the contract as matched" do
        expect(resolve.schema_contract).to eq(:matched)
      end

      it "runs normally, changing neither stdout nor the exit code" do
        stdout, _stderr, code = run_cli({ described_class::ENV_VAR => clean_stub })

        expect(code).to eq(SpecGuard::RSpec::CLI::EXIT_OK)
        expect(stdout).to include("specguard-lint: checked 1 @intent annotation, 0 malformed")
      end

      # The wording constraint, and it is not a style note. `LoadSchema` gives a
      # schema file found beside the executable priority over the embedded copy,
      # and `--version` returns above that decision — so the digest is the
      # contract the artifact CARRIES, and a line claiming the run ENFORCED it
      # would be this gem inventing a guarantee the answer does not contain.
      it "says the contract matched without claiming the run enforced it" do
        stub = clean_stub
        line = provenance_of({ described_class::ENV_VAR => stub })

        expect(line).to eq("specguard-lint: validated by #{stub_identity} at #{stub} " \
                           "(SPECGUARD_VALIDATE_INTENT), which reports carrying the schema this gem " \
                           "vendors — the contract it carries, not necessarily the one this run enforced")
        expect(line).to include("not necessarily the one this run enforced")
      end

      # The comparison reads the identity the probe already obtained, so it must
      # not cost a second process — and, more importantly, the name in the line
      # and the digest that was compared must have come from the same answer.
      it "compares without asking the binary a second time" do
        run_backend(["a_spec.rb"], stdout: document([ok_finding]))

        expect(version_probes.length).to eq(1)
      end

      # A future build may word its version differently and still be telling the
      # truth: only the token is read, everything around it stays opaque.
      it "reads the token out of a line it otherwise does not understand" do
        runner = resolve(version_stdout: "sg-validator/2 (experimental) schema sha256:#{vendored_digest} +tls")

        expect(runner.schema_contract).to eq(:matched)
      end

      # Go's hex is lower case and so is Ruby's, so this changes nothing today;
      # it is here so that a build which shouts is read as the same digest
      # rather than reported as a divergence that does not exist.
      it "treats an upper-case spelling as the same digest" do
        expect(resolve(version_stdout: identity_reporting(vendored_digest.upcase)).schema_contract).to eq(:matched)
      end
    end

    # ---------------------------------------------------------------------- #
    # BAND (b): reported and different. The one addition to the exit-2 band.
    describe "a binary carrying a different schema" do
      def diverging_stub(**stub)
        clean_stub(version_stdout: identity_reporting(foreign_digest), **stub)
      end

      it "refuses to resolve" do
        expect { resolve(version_stdout: identity_reporting(foreign_digest)) }
          .to raise_error(SpecGuard::RSpec::ValidatorError)
      end

      it "exits 2, not 1 — this is not a verdict about anyone's annotations" do
        _, _, code = run_cli({ described_class::ENV_VAR => diverging_stub })

        expect(code).to eq(SpecGuard::RSpec::CLI::EXIT_MISUSE)
      end

      # Both digests, in full. One of them lives inside a binary and the other
      # inside an installed gem, and neither is inspectable from where the other
      # lives — a message naming one would send the reader off to compute the
      # other by hand. The version string is named too: this refusal happens
      # above the provenance line, so if the error does not say which build
      # reported the foreign digest, nothing in the run does.
      it "names both digests, and the binary it read one of them from" do
        stub = diverging_stub
        _, stderr, = run_cli({ described_class::ENV_VAR => stub })

        expect(error_lines(stderr).length).to eq(1)
        expect(error_lines(stderr).first).to include("the validator backend at #{stub}")
        expect(error_lines(stderr).first).to include("sha256:#{foreign_digest}")
        expect(error_lines(stderr).first).to include("sha256:#{vendored_digest}")
        expect(error_lines(stderr).first).to include(identity_reporting(foreign_digest))
      end

      # The provenance line is not printed on this path — the refusal is raised
      # inside .resolve, above the reporting — which is why the version string
      # has to be in the error itself rather than left to the line beside it.
      it "is the only place the run names the build, because provenance never prints" do
        _, stderr, = run_cli({ described_class::ENV_VAR => diverging_stub })

        expect(stderr).not_to include("specguard-lint: validated")
      end

      # The whole reason the check sits in #verify!: the divergence is settled
      # before a single file is selected, scanned or handed to the binary.
      it "fails before anything is selected or scanned" do
        stdout, stderr, = run_cli({ described_class::ENV_VAR => diverging_stub })

        expect(recorded_invocations).to be_empty
        expect(stdout).to eq("")
        expect(stderr).not_to include("selected")
      end

      # It would have been a clean run. That is the point: nothing downstream —
      # not the report, not the exit code, not the finding count — could have
      # told anyone the verdict came from a different contract.
      it "refuses a run that would otherwise have passed" do
        clean = run_cli({ described_class::ENV_VAR => clean_stub(name: "agreeing") })
        diverged = run_cli({ described_class::ENV_VAR => diverging_stub(name: "diverging") })

        expect(clean[2]).to eq(SpecGuard::RSpec::CLI::EXIT_OK)
        expect(diverged[2]).to eq(SpecGuard::RSpec::CLI::EXIT_MISUSE)
      end
    end

    # ---------------------------------------------------------------------- #
    # BAND (c): not reported — never a refusal, in any of its three shapes.
    #
    # The standing rule this file already enforces for identity ("an older build
    # must not cost a verdict") applies unchanged: slice 17 is newer than the
    # binaries in the field, and a gem that refused every one of them would be
    # enforcing a contract by breaking everybody who cannot yet state theirs.
    describe "a binary that reports no digest" do
      it "records the contract as unreported, and still resolves" do
        expect(resolve(version_stdout: "validate-intent 1.4.0 (go1.22.12 linux/arm64)").schema_contract)
          .to eq(:unreported)
      end

      it "still validates, with the exit code unchanged" do
        stub = clean_stub(version_stdout: "validate-intent 1.4.0 (go1.22.12 linux/arm64)")
        stdout, _stderr, code = run_cli({ described_class::ENV_VAR => stub })

        expect(code).to eq(SpecGuard::RSpec::CLI::EXIT_OK)
        expect(stdout).to include("specguard-lint: checked 1 @intent annotation, 0 malformed")
      end

      # "Could not check" is a different statement from "checked and clean", and
      # a run that made the first while looking like the second is this project's
      # signature defect. So it is said, in its own words.
      it "says the contract could not be checked" do
        stub = clean_stub(version_stdout: "validate-intent 1.4.0 (go1.22.12 linux/arm64)")

        expect(provenance_of({ described_class::ENV_VAR => stub }))
          .to eq("specguard-lint: validated by validate-intent 1.4.0 (go1.22.12 linux/arm64) at #{stub} " \
                 "(SPECGUARD_VALIDATE_INTENT), which reports no schema digest, " \
                 "so the contract it carries could not be checked")
      end

      # A token this gem cannot read is not a token it disagrees with. Sixty-five
      # hex digits is not a SHA-256, and matching its first sixty-four would
      # compare against something nobody wrote.
      it "treats a malformed token as no token rather than as a divergence" do
        %W[schema\ sha256:#{vendored_digest}0 schema\ sha256:#{vendored_digest[0..62]} schema\ sha256:zz].each do |tail|
          runner = resolve(version_stdout: "validate-intent 1.4.0 #{tail}", name: "stub-#{tail.bytesize}")

          expect(runner.schema_contract).to eq(:unreported)
        end
      end
    end

    describe "a binary that cannot report its identity at all" do
      it "records the contract as unidentified, and still validates" do
        stub = clean_stub(version_stdout: "", version_exit: 1)
        runner = described_class.resolve(env: { described_class::ENV_VAR => stub })
        stdout, _stderr, code = run_cli({ described_class::ENV_VAR => stub })

        expect(runner.schema_contract).to eq(:unidentified)
        expect(code).to eq(SpecGuard::RSpec::CLI::EXIT_OK)
        expect(stdout).to include("specguard-lint: checked 1 @intent annotation, 0 malformed")
      end

      # Distinct wording from the sub-case above. Both mean "not checked", but
      # an operator has to be able to tell a build too old to answer from one
      # that answered without a digest — they are fixed differently.
      it "says so in its own words, distinct from the digest-less arm" do
        anonymous = clean_stub(name: "anonymous", version_stdout: "", version_exit: 1)
        digestless = clean_stub(name: "digestless", version_stdout: "validate-intent 1.4.0")

        lines = [provenance_of({ described_class::ENV_VAR => anonymous }),
                 provenance_of({ described_class::ENV_VAR => digestless })]

        expect(lines.first).to end_with("which could not report its identity, " \
                                        "so the schema contract it carries could not be checked")
        expect(lines.uniq.length).to eq(2)
      end
    end

    # ---------------------------------------------------------------------- #
    # THE THIRD SHAPE, and the judgment call recorded in the module comment.
    #
    # `Schema.load`'s precedent is that an unreadable SCHEMA_PATH is exit 2 —
    # but that is a schema the run is about to ENFORCE, and this one is not:
    # `CLI#run` skips the load on this path precisely so an unrelated packaging
    # accident cannot fail a run that never reads it, and a fatal digest here
    # would re-introduce the dependency that comment removed. A missing operand
    # is also not a divergence: the exit-2 band is for two digests that differ.
    describe "a gem that cannot read its own vendored schema" do
      # The digest is read BEFORE the constant is stubbed away, so the stub
      # binary still reports what a healthy gem would compute. What this group
      # removes is the gem's HALF of the comparison and nothing else — with
      # both halves gone there would be no comparison to have, and the examples
      # would pass for the wrong reason.
      before do
        @healthy_digest = vendored_digest
        stub_const("SpecGuard::RSpec::SCHEMA_PATH", File.join(tmpdir, "not-vendored.json"))
      end

      def unreadable_stub(**stub)
        clean_stub(version_stdout: identity_reporting(@healthy_digest), **stub)
      end

      it "does not refuse the run" do
        expect { described_class.resolve(env: { described_class::ENV_VAR => unreadable_stub }) }
          .not_to raise_error
      end

      it "records the contract as unreadable, and still validates" do
        stub = unreadable_stub
        runner = described_class.resolve(env: { described_class::ENV_VAR => stub })
        stdout, _stderr, code = run_cli({ described_class::ENV_VAR => stub })

        expect(runner.schema_contract).to eq(:unreadable)
        expect(code).to eq(SpecGuard::RSpec::CLI::EXIT_OK)
        expect(stdout).to include("specguard-lint: checked 1 @intent annotation, 0 malformed")
      end

      it "says which half could not be read" do
        stub = unreadable_stub

        expect(provenance_of({ described_class::ENV_VAR => stub }))
          .to end_with("whose schema contract could not be checked: " \
                       "this gem could not read its own vendored copy")
      end
    end

    # ---------------------------------------------------------------------- #
    # THE PRODUCT DOES NOT MOVE. The provenance line is stderr prose about the
    # linter's own configuration; the findings and the two `checked …` lines are
    # the product, and they are pinned byte-for-byte across the backends
    # everywhere above. Which band a run lands in must not reach them.
    it "leaves stdout byte-identical across every band that is not a refusal" do
      stdouts = [clean_stub(name: "matched"),
                 clean_stub(name: "digestless", version_stdout: "validate-intent 1.4.0"),
                 clean_stub(name: "silent", version_stdout: "", version_exit: 1)]
                .map { |stub| run_cli({ described_class::ENV_VAR => stub }) }

      expect(stdouts.map(&:first).uniq.length).to eq(1)
      expect(stdouts.map(&:last).uniq).to eq([SpecGuard::RSpec::CLI::EXIT_OK])
    end

    it "moves only the provenance line between those bands" do
      matched = run_cli({ described_class::ENV_VAR => clean_stub(name: "a-matched") })
      digestless = run_cli({ described_class::ENV_VAR =>
                             clean_stub(name: "a-digestless", version_stdout: "validate-intent 1.4.0") })

      expect(stderr_beyond_provenance(digestless[1])).to eq(stderr_beyond_provenance(matched[1]))
      expect(provenance_lines(digestless[1])).not_to eq(provenance_lines(matched[1]))
    end

    # ---------------------------------------------------------------------- #
    # The invariant that keeps this check honest. A constant holding the digest
    # would be a fourth copy of a hex string that already exists in three
    # places, free to drift from the file it claims to describe — which is the
    # precise defect this check was added to detect, re-created inside the
    # detector. `schema_packaging_spec.rb` stays the single pin in this repo.
    it "computes the digest at runtime rather than writing a fourth copy of it" do
      root = File.expand_path("../../..", __dir__)
      # ANY 64-hex literal, not this one. The copy that would be the bug is a
      # STALE pin — written down when canonical was some other value and left
      # behind after it changed — and such a constant shares no characters with
      # the digest that is correct today. Grepping for the current digest would
      # catch only the harmless case and pass over the defect this whole slice
      # exists to detect, re-created inside its own detector.
      out, err, status = Open3.capture3("git", "grep", "-nIE", "[0-9a-fA-F]{64}", "--", "lib/", chdir: root)

      # `git grep` exits 0 having found matches, 1 having searched and found
      # none, and 128 when it could not search at all — not a checkout, an
      # exported tree, a gem unpacked from a .gem file. The output is empty in
      # two of those three, so an example that read the output alone would go
      # green in an environment where it verified nothing: the vacuous green
      # this file names elsewhere, reproduced inside the guard. The status is
      # therefore asserted first, and separately.
      expect([0, 1]).to include(status.exitstatus),
                        "git grep could not search #{root} (exit #{status.exitstatus}): #{err}"
      expect(out).to eq("")
    end
  end

  # ------------------------------------------------------------------------ #
  # `--require-validator`: making the provenance line ACTIONABLE.
  #
  # The line above says which implementation ran. Nothing could act on it — it
  # is stderr prose, and there was no flag, variable or exit code with which a
  # caller could say "I asked for the binary; fail if I did not get it."
  #
  # The named-but-broken cases were never the gap: `SPECGUARD_VALIDATE_INTENT`
  # pointing at a missing or unusable binary already raises out of #verify! and
  # exits 2. The gap is the variable that never arrived at all — a mistyped
  # name, a conditional CI step that did not run, an unloaded environment file.
  # The run then passes, validated by the OTHER implementation, and looks
  # exactly like the run that was asked for.
  #
  # And the two implementations are not interchangeable on every input: their
  # JSON parsers accept different languages, so on a documented input class the
  # two backends disagree on the EXIT CODE with nothing in the report to say so.
  # A gate whose failure states are indistinguishable — for the third time.
  describe "--require-validator" do
    let(:paths) { %w[spec/fixtures/order_spec.rb] }

    def run_cli(env, argv)
      stdout = StringIO.new
      stderr = StringIO.new
      code = SpecGuard::RSpec::CLI.new(stdout: stdout, stderr: stderr, env: env).run(argv)
      [stdout.string, stderr.string, code]
    end

    def error_lines(stderr)
      stderr.lines.map(&:chomp).select { |line| line.start_with?("specguard-lint: error: ") }
    end

    # ---------------------------------------------------------------------- #
    # THE CASE THAT DID NOT EXIST BEFORE. Exit 2, not 1: "the linter could not
    # do its job" is the band a named-but-missing binary already lands in, and
    # a 1 would report a malformed annotation that nobody wrote.
    describe "when the backend did not run" do
      it "exits 2 with an unset variable" do
        _, _, code = run_cli({}, ["--require-validator", *paths])

        expect(code).to eq(SpecGuard::RSpec::CLI::EXIT_MISUSE)
      end

      it "names the variable and says it is unset" do
        _, stderr, = run_cli({}, ["--require-validator", *paths])

        expect(error_lines(stderr))
          .to eq(["specguard-lint: error: --require-validator was given, but " \
                  "SPECGUARD_VALIDATE_INTENT is unset, so this run would have been validated in Ruby"])
      end

      # Asking for the binary and turning it off in the same breath is a
      # contradiction, and a contradiction resolved in the caller's favour
      # silently is the whole defect. So it is a 2, and it says which of the two
      # nil causes happened rather than collapsing them the way .resolve does.
      it "exits 2 on a blank value too, in the provenance line's own words" do
        stdout, stderr, code = run_cli({ described_class::ENV_VAR => "" }, ["--require-validator", *paths])

        expect(code).to eq(SpecGuard::RSpec::CLI::EXIT_MISUSE)
        expect(error_lines(stderr))
          .to eq(["specguard-lint: error: --require-validator was given, but " \
                  "SPECGUARD_VALIDATE_INTENT is set but blank, which means off, " \
                  "so this run would have been validated in Ruby"])
        expect(stdout).to be_empty
      end

      it "treats a whitespace-only value as blank, matching .resolve" do
        _, stderr, code = run_cli({ described_class::ENV_VAR => "   " }, ["--require-validator", *paths])

        expect(code).to eq(SpecGuard::RSpec::CLI::EXIT_MISUSE)
        expect(stderr).to include("is set but blank, which means off")
      end

      # The two sentences describe the same two states, so they must use the
      # same two words. Asserted by construction rather than by eye: the
      # parenthetical of the provenance line is a substring of the failure.
      it "reuses the provenance line's vocabulary verbatim" do
        [{}, { described_class::ENV_VAR => "" }].each do |env|
          _, stderr, = run_cli(env, ["--require-validator", *paths])
          reason = provenance_lines(stderr).first[/validated in Ruby \((.*)\)\z/, 1]

          expect(reason).not_to be_nil
          expect(error_lines(stderr).first).to include(reason)
        end
      end

      # Placement. The provenance line still comes first — stderr carries what
      # DID validate the run before the reason that was not good enough — and
      # the raise sits before selection, so nothing is selected, scanned or
      # reported. A refusal that still printed "checked 1 @intent annotation"
      # would be a verdict from the implementation the caller just refused.
      it "reports the provenance first, then refuses" do
        _, stderr, = run_cli({}, ["--require-validator", *paths])

        expect(stderr.lines.first).to eq("specguard-lint: validated in Ruby " \
                                         "(SPECGUARD_VALIDATE_INTENT is unset)\n")
        expect(stderr.lines.last).to start_with("specguard-lint: error: ")
      end

      it "selects, scans and reports nothing" do
        stdout, stderr, = run_cli({}, ["--require-validator", *paths])

        expect(stdout).to be_empty
        expect(stderr).not_to include("checked")
        expect(stderr).not_to include("selected")
      end

      # It is a refusal by the linter, not a verdict about anyone's
      # annotations, and not a crash either.
      it "does not reach the malformed-annotation code or the internal backstop" do
        _, stderr, code = run_cli({}, ["--require-validator", *paths])

        expect(code).not_to eq(SpecGuard::RSpec::CLI::EXIT_MALFORMED)
        expect(stderr).not_to include("internal error")
      end
    end

    # ---------------------------------------------------------------------- #
    # THE ASSERTION THAT HOLDS COSTS NOTHING. The flag is an assertion about the
    # configuration, so on the configuration it asserts, it must be invisible.
    describe "when the backend did run" do
      it "changes nothing about a run the binary validated" do
        stub = clean_stub
        without = run_cli({ described_class::ENV_VAR => stub }, paths)
        with = run_cli({ described_class::ENV_VAR => stub }, ["--require-validator", *paths])

        expect(with).to eq(without)
      end

      it "is satisfied by a binary that cannot report its identity" do
        stub = clean_stub(version_stdout: "", version_exit: 1)
        _, stderr, code = run_cli({ described_class::ENV_VAR => stub }, ["--require-validator", *paths])

        expect(code).to eq(SpecGuard::RSpec::CLI::EXIT_OK)
        expect(error_lines(stderr)).to be_empty
      end

      # The flag adds no failure mode of its own to the named-but-broken case:
      # that was already a hard 2 out of #verify!, and it still is, with its own
      # message rather than this one.
      it "leaves a named-but-unusable binary failing for its own reason" do
        missing = File.join(tmpdir, "not-there")
        _, with_flag, code = run_cli({ described_class::ENV_VAR => missing }, ["--require-validator", *paths])
        _, without_flag, = run_cli({ described_class::ENV_VAR => missing }, paths)

        expect(code).to eq(SpecGuard::RSpec::CLI::EXIT_MISUSE)
        expect(with_flag).to eq(without_flag)
        expect(with_flag).not_to include("--require-validator")
      end
    end

    # ---------------------------------------------------------------------- #
    # WITHOUT THE FLAG, NOTHING MOVED. The backend stays opt-in and off by
    # default — the binary is a gitignored build artifact with no release, so
    # default-on would turn every existing user's working linter into an error.
    it "is off unless asked for" do
      expect(run_cli({}, paths)[2]).to eq(SpecGuard::RSpec::CLI::EXIT_OK)
      expect(run_cli({ described_class::ENV_VAR => "" }, paths)[2]).to eq(SpecGuard::RSpec::CLI::EXIT_OK)
    end
  end
end
