# frozen_string_literal: true

require "tmpdir"
require "fileutils"
require "open3"

# The 0/1/2 exit contract (SPGD-12 §1), and the defence around it.
#
# Ruby maps *every* internal failure onto exit 1 — `ruby -e 'raise "boom"'`
# exits 1, and so does an uncaught `OptionParser::InvalidOption`. The contract
# has already spent 1 on "an annotation is malformed", so on the obvious
# implementation a typo'd FLAG makes CI accuse a developer of a bad annotation
# that does not exist. These examples are what keeps 1 meaning one thing.
RSpec.describe "the specguard-lint exit contract" do
  subject(:cli) { SpecGuard::RSpec::CLI.new(stdout: stdout, stderr: stderr) }

  let(:stdout) { StringIO.new }
  let(:stderr) { StringIO.new }

  def out = stdout.string
  def err = stderr.string

  describe "0 — clean" do
    it "exits 0 on a file whose annotations are all valid" do
      expect(cli.run([fixture_path("order_spec.rb")])).to eq(0)
    end

    # "Lint, don't require": a file with no @intent: at all is not an error.
    # This is the one thing the contract will NOT let the exit code express,
    # which is why the empty selection is loud on stderr instead.
    it "exits 0 on a spec file carrying no annotations at all" do
      Dir.mktmpdir do |dir|
        File.write(File.join(dir, "bare_spec.rb"), "RSpec.describe(Order) { it('works') {} }\n")

        expect(cli.run([File.join(dir, "bare_spec.rb")])).to eq(0)
      end
    end

    it "exits 0 when nothing at all was selected, but says so on stderr" do
      Dir.mktmpdir do |dir|
        Dir.chdir(dir) { expect(cli.run([])).to eq(0) }
      end

      expect(err).to include("selected 0 spec files")
    end
  end

  describe "1 — malformed annotation" do
    # Criterion 1.
    it "exits 1 on a truncated behavior, naming file, line and the violation" do
      Dir.mktmpdir do |dir|
        path = File.join(dir, "short_spec.rb")
        File.write(path, <<~RUBY)
          RSpec.describe Order do
            # @intent: { entity: "Order", action: "total", behavior: "sums", layer: "unit" }
            it "sums" do
            end
          end
        RUBY

        expect(cli.run([path])).to eq(1)
        expect(out).to include("FAIL  #{path}:2")
        expect(out).to include("-> behavior: string is 4 char(s), minLength is 15")
      end
    end

    it "exits 1 on an annotation that could not be extracted at all" do
      Dir.mktmpdir do |dir|
        path = File.join(dir, "typo_spec.rb")
        File.write(path, "# @intent:\n")

        expect(cli.run([path])).to eq(1)
      end
    end

    # Criterion 8. Stopping at the first would turn this one file into five CI
    # round-trips; the reference reports all five, and the report-all
    # divergence from SPGD-12 §1 step 4's "first" wording is ratified.
    it "reports every failing annotation, not the first" do
      expect(cli.run([fixture_path("broken_intent_spec.rb")])).to eq(1)

      expect(out.scan(/^FAIL  /).length).to eq(5)
      expect(out.scan(/^FAIL  \S+:(\d+)/).flatten).to eq(%w[9 15 21 28 34])
    end

    it "reports every reason for a single annotation, not the first" do
      cli.run([fixture_path("broken_intent_spec.rb")])

      # Lines 9 and 21 each violate two rules.
      blocks = out.split(/^FAIL  /).drop(1)
      reasons_per_block = blocks.map { |block| block.scan(/^        -> /).length }

      expect(reasons_per_block).to eq([2, 1, 2, 0, 0])
    end

    it "states the totals so a run that checked nothing cannot read as a clean one" do
      cli.run([fixture_path("broken_intent_spec.rb")])

      expect(out).to include("specguard-lint: checked 5 @intent annotations, 5 malformed")
    end
  end

  describe "2 — the linter could not do its job" do
    # Criterion 3. THE case: uncaught, OptionParser::InvalidOption is a 1.
    it "exits 2 on an unknown flag rather than accusing an annotation" do
      expect(cli.run(["--bogus"])).to eq(2)
      expect(err).to include("invalid option: --bogus")
    end

    it "exits 2 on a typo of a real flag" do
      expect(cli.run(["--chnaged"])).to eq(2)
    end

    # The generic backstop would also turn an unrescued ParseError into a 2, so
    # the exit code alone does not prove the flag was recognised AS misuse.
    # A user who mistypes a flag must be told they mistyped a flag, not that
    # the linter has a bug.
    it "reports a bad flag as misuse rather than as an internal error" do
      cli.run(["--bogus"])

      expect(err).to start_with("specguard-lint: error:")
      expect(err).not_to include("internal error")
    end

    # Criterion 4.
    it "exits 2 when --changed is used outside a git repository" do
      Dir.mktmpdir do |dir|
        Dir.chdir(dir) { expect(cli.run(["--changed"])).to eq(2) }
      end

      expect(err).to include("--changed requires a git repository")
    end

    it "exits 2 when --changed is combined with explicit files" do
      expect(cli.run(["--changed", fixture_path("order_spec.rb")])).to eq(2)
      expect(out).not_to include("checked")
    end

    # Criterion 5 — parity with bin/validate-intent:858-862, which prints
    # `error: could not load schema ...` and returns 2.
    describe "an unloadable vendored schema" do
      it "exits 2 when the schema file is missing" do
        stub_const("SpecGuard::RSpec::SCHEMA_PATH", "/nonexistent/open-test-intent.v1.json")

        expect(cli.run([fixture_path("order_spec.rb")])).to eq(2)
      end

      # The wording and the stream, not the position: the run also names the
      # validator that was about to produce the verdicts (CLI#report_backend),
      # and that line is emitted before the schema is loaded.
      it "says so on stderr, in the validator's words" do
        stub_const("SpecGuard::RSpec::SCHEMA_PATH", "/nonexistent/open-test-intent.v1.json")
        cli.run([fixture_path("order_spec.rb")])

        expect(err.lines).to include(a_string_starting_with("error: could not load schema /nonexistent/"))
      end

      it "exits 2 when the schema file is present but unparseable" do
        Dir.mktmpdir do |dir|
          broken = File.join(dir, "open-test-intent.v1.json")
          File.write(broken, "{ not json")
          stub_const("SpecGuard::RSpec::SCHEMA_PATH", broken)

          expect(cli.run([fixture_path("order_spec.rb")])).to eq(2)
        end
      end

      # The failure has to happen BEFORE anything is checked. A linter that
      # scans first and only then discovers it has no schema could report
      # "0 malformed" over a file full of violations — this project's signature
      # vacuous-green defect, arrived at from the other side.
      it "fails before it validates anything, rather than reporting a vacuous clean run" do
        stub_const("SpecGuard::RSpec::SCHEMA_PATH", "/nonexistent/open-test-intent.v1.json")
        cli.run([fixture_path("broken_intent_spec.rb")])

        expect(out).not_to include("malformed")
        expect(out).not_to include("FAIL")
      end
    end

    # Criterion 6. The backstop: whatever breaks, it is never a 1.
    describe "an unexpected internal exception" do
      it "exits 2 rather than letting Ruby's default 1 stand" do
        allow(SpecGuard::RSpec::Scanner).to receive(:scan_files).and_raise("boom")

        expect(cli.run([fixture_path("order_spec.rb")])).to eq(2)
      end

      it "reports it as an internal error, not as a malformed annotation" do
        allow(SpecGuard::RSpec::Scanner).to receive(:scan_files).and_raise("boom")
        cli.run([fixture_path("order_spec.rb")])

        expect(err).to include("specguard-lint: internal error: RuntimeError: boom")
        expect(out).not_to include("FAIL")
      end

      it "catches a NoMethodError from deep inside the pipeline too" do
        allow(SpecGuard::RSpec::Linter).to receive(:new).and_raise(NoMethodError, "undefined method")

        expect(cli.run([fixture_path("order_spec.rb")])).to eq(2)
      end

      # ScriptError is not a StandardError, so a bare `rescue` misses it and
      # Ruby exits 1 again.
      it "catches a ScriptError, which a bare rescue would miss" do
        allow(SpecGuard::RSpec::Scanner).to receive(:scan_files).and_raise(NotImplementedError, "nope")

        expect(cli.run([fixture_path("order_spec.rb")])).to eq(2)
      end

      # Ctrl-C must stay Ctrl-C. Mapping a signal onto "the linter is broken"
      # would be its own small lie, and would make the tool un-interruptible.
      it "does NOT swallow an interrupt" do
        allow(SpecGuard::RSpec::Scanner).to receive(:scan_files).and_raise(Interrupt)

        expect { cli.run([fixture_path("order_spec.rb")]) }.to raise_error(Interrupt)
      end
    end
  end

  # SPGD-305. `--json` is a second RENDERER over the same Linter::Result list,
  # so the contract above must be completely indifferent to it. That is easy to
  # believe and cheap to break — the flag touches #report_selection and
  # #report_results, both of which sit on the path to the return value — so it
  # is asserted at all three codes rather than argued for.
  #
  # The pairs run the SAME argv twice and compare the two codes to each other as
  # well as to the expected one. A regression that moved both (say, a renderer
  # that started swallowing an exception) would satisfy "they agree" alone.
  describe "--json changes the renderer and nothing about the exit code" do
    def code_for(argv, chdir: nil)
      run = lambda do
        SpecGuard::RSpec::CLI.new(stdout: StringIO.new, stderr: StringIO.new).run(argv)
      end

      chdir ? Dir.mktmpdir { |dir| Dir.chdir(dir) { run.call } } : run.call
    end

    ORDER = File.join(FixtureHelpers::FIXTURE_ROOT, "order_spec.rb")
    BROKEN = File.join(FixtureHelpers::FIXTURE_ROOT, "broken_intent_spec.rb")

    {
      "a clean file" => [0, [ORDER], false],
      "nothing selected at all" => [0, [], true],
      "malformed annotations" => [1, [BROKEN], false],
      "a file that could not be read" => [1, ["gone_spec.rb"], true],
      "an unknown flag" => [2, ["--bogus"], false],
      "--changed combined with explicit files" => [2, ["--changed", ORDER], false],
      "--changed outside a git repository" => [2, ["--changed"], true]
    }.each do |name, (expected, argv, in_tmpdir)|
      it "exits #{expected} either way on #{name}" do
        plain = code_for(argv, chdir: in_tmpdir)
        json = code_for(["--json", *argv], chdir: in_tmpdir)

        expect(json).to eq(plain)
        expect(json).to eq(expected)
      end
    end

    # `--require-validator` is the one exit-2 path that is about the run rather
    # than the arguments, and it is reached before any renderer is chosen.
    it "exits 2 on an unmet --require-validator with and without the flag" do
      plain = SpecGuard::RSpec::CLI.new(stdout: StringIO.new, stderr: StringIO.new, env: {})
                                   .run(["--require-validator", fixture_path("order_spec.rb")])
      json = SpecGuard::RSpec::CLI.new(stdout: StringIO.new, stderr: StringIO.new, env: {})
                                  .run(["--json", "--require-validator", fixture_path("order_spec.rb")])

      expect(json).to eq(plain)
      expect(json).to eq(2)
    end
  end

  describe "#run never raises, whatever it is handed" do
    # The contract is only worth something if the process cannot exit any other
    # way. Every argv shape that has a plausible path to an exception.
    [
      [],
      ["--bogus"],
      ["--changed"],
      ["--changed", "--bogus"],
      ["/nonexistent/gone_spec.rb"],
      ["--"],
      ["-x"]
    ].each do |argv|
      it "returns 0, 1 or 2 for #{argv.inspect}" do
        code = nil
        Dir.mktmpdir { |dir| Dir.chdir(dir) { expect { code = cli.run(argv) }.not_to raise_error } }

        expect(code).to be_between(0, 2)
      end
    end
  end

  # The library returning 2 is necessary but not sufficient: the exit code the
  # shell sees is the product. These run the real executable in a subprocess.
  describe "bin/specguard-lint, end to end in a real process" do
    def lint(*args, chdir: Dir.pwd)
      exe = File.expand_path("../../../bin/specguard-lint", __dir__)
      _out, _err, status = Open3.capture3(RbConfig.ruby, exe, *args, chdir: chdir)
      status.exitstatus
    end

    it "exits 0 on a clean file" do
      expect(lint(fixture_path("order_spec.rb"))).to eq(0)
    end

    it "exits 1 on malformed annotations" do
      expect(lint(fixture_path("broken_intent_spec.rb"))).to eq(1)
    end

    it "exits 2 on an unknown flag" do
      expect(lint("--bogus")).to eq(2)
    end

    it "exits 2 on --changed outside a git repository" do
      Dir.mktmpdir { |dir| expect(lint("--changed", chdir: dir)).to eq(2) }
    end

    # The library returning the same code under --json is necessary but not
    # sufficient for the same reason the rest of this section exists: what CI
    # reads is the process's exit status.
    it "exits 0, 1 and 2 identically under --json" do
      expect(lint("--json", fixture_path("order_spec.rb"))).to eq(0)
      expect(lint("--json", fixture_path("broken_intent_spec.rb"))).to eq(1)
      expect(lint("--json", "--bogus")).to eq(2)
    end
  end
end
