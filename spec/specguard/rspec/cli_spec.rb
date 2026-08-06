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

  describe "the exit contract is NOT this slice" do
    # Nothing here validates anything yet, so a non-zero exit would be a lie.
    # These pin criterion 7: bin/specguard-lint exits 0 in every case.
    it "exits 0 on a clean file" do
      expect(cli.run([fixture_path("order_spec.rb")])).to eq(0)
    end

    it "exits 0 on a file full of schema violations and malformed annotations" do
      expect(cli.run([fixture_path("broken_intent_spec.rb")])).to eq(0)
    end

    it "exits 0 on a misuse that will later be a 2" do
      Dir.mktmpdir do |dir|
        Dir.chdir(dir) { expect(cli.run(["--changed"])).to eq(0) }
      end
    end

    it "exits 0 on an unparseable command line" do
      expect(cli.run(["--no-such-flag"])).to eq(0)
    end

    it "exits 0 when nothing at all is selected" do
      Dir.mktmpdir { |dir| Dir.chdir(dir) { expect(cli.run([])).to eq(0) } }
    end
  end

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

    it "summarises the annotations it found" do
      cli.run([fixture_path("broken_intent_spec.rb")])

      expect(out).to include("found 5 @intent annotations (3 extracted, 2 malformed)")
    end

    it "prints each malformed annotation at its own file:line on stderr" do
      cli.run([fixture_path("broken_intent_spec.rb")])

      expect(err).to include(":28: unterminated object literal")
      expect(err).to include(":34: no '{...}' object literal")
    end

    it "prints each extracted annotation as strict JSON" do
      cli.run([fixture_path("order_spec.rb")])

      expect(out).to include(':10: {"entity":"Order","action":"checkout"')
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
  end

  describe "reading files" do
    it "reports an unreadable file rather than aborting the whole run" do
      Dir.mktmpdir do |dir|
        missing = File.join(dir, "gone_spec.rb")

        expect { cli.run([missing]) }.not_to raise_error
        expect(err).to include("could not read file")
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

    it "still exits 0, since the exit contract is the next slice" do
      expect(cli.run(["--changed", fixture_path("order_spec.rb")])).to eq(0)
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
