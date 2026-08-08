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
    # The reference drops the line for exactly these findings
    # (bin/validate-intent:521), and this is the one output shape the suite
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
    # KIND_READ — the reference tool's own name for it — so the decision to
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
  end
end
