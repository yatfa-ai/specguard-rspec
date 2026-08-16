# frozen_string_literal: true

require "json"
require "stringio"
require "tmpdir"

require "specguard/rspec/ingest_cli"

require_relative "../../support/stub_ingest_endpoint"

# `specguard-ingest`, against a real socket.
#
# The command exists to make one README sentence true — the formatter writes an
# undelivered run to `log/test_results.jsonl` "so the run can be replayed later"
# — and the thing worth testing is therefore not that a method was called but
# that a saved line comes back off disk and lands on the endpoint as the same
# body it was refused as. So this drives {StubIngestEndpoint} rather than a
# double, exactly as `transport_spec.rb` does and for the reason argued there.
#
# The other half is the exit contract, which is `specguard-lint`'s (SPGD-12 §1)
# transferred: Ruby maps every internal failure onto exit 1, and 1 is already
# spent here on "the endpoint refused a line". Every exit-2 example below is
# guarding the same property from a different door — a tool failure must never
# borrow the code that means "the platform said no to your run".
#
# NOT registered in `regression_targets_spec.rb`, deliberately. That file locks
# `specguard-lint`'s default output path for SPGD-305's constraint (the `--json`
# renderer must not have moved a byte of the human one), and this command has no
# second renderer to hold it to. The byte-exact expectations it would hold live
# here instead, next to the behaviour they describe.
RSpec.describe SpecGuard::RSpec::IngestCLI do
  subject(:cli) { described_class.new(stdout: stdout, stderr: stderr, env: env) }

  let(:stdout) { StringIO.new }
  let(:stderr) { StringIO.new }
  let(:endpoint) { nil }
  let(:api_key) { "sgk_abc123" }
  let(:env) do
    { "SPECGUARD_ENDPOINT" => endpoint, "SPECGUARD_API_KEY" => api_key, "SPECGUARD_TIMEOUT" => "5" }.compact
  end

  def out = stdout.string
  def err = stderr.string

  # One whole run, as `SpecGuard::RSpecFormatter#payload` assembles it and as
  # `#append` writes it: `JSON.generate` over the same Hash the transport would
  # have posted, which is the identity this command is built on.
  def run_payload(ci_run_id: "17442", commit_sha: "0d4a1f2c9b8e7d6a5f4c3b2a1908f7e6d5c4b3a2")
    {
      "commit_sha" => commit_sha,
      "branch" => "main",
      "ci_run_id" => ci_run_id,
      "shard_id" => "1",
      "duration_seconds" => 1.25,
      "specs" => [
        { "id" => "./spec/orders_spec.rb[1:1]", "spec_file_path" => "spec/orders_spec.rb",
          "file_path" => "spec/orders_spec.rb", "line_number" => 4, "name" => "Order checks out",
          "duration" => 0.01, "outcome" => "passed", "status" => "unannotated", "intent" => nil }
      ]
    }
  end

  # A sink file with the given lines, written exactly as the formatter writes
  # one: `JSON.generate(data)` plus a newline, appended.
  def sink(*lines)
    path = File.join(@dir, "test_results.jsonl")
    File.write(path, lines.map { |line| "#{line.is_a?(String) ? line : JSON.generate(line)}\n" }.join)
    path
  end

  around do |example|
    Dir.mktmpdir do |dir|
      @dir = dir
      example.run
    end
  end

  # A port nothing is listening on. Bound and released rather than picked out of
  # the air, so the example cannot collide with something that happens to be
  # running on this machine.
  def dead_endpoint
    server = TCPServer.new("127.0.0.1", 0)
    port = server.addr[1]
    server.close
    "http://127.0.0.1:#{port}"
  end

  describe "0 — every line accepted" do
    it "re-delivers the saved line as the body the endpoint was offered, byte for byte" do
      payload = run_payload

      StubIngestEndpoint.run do |server|
        code = described_class.new(stdout: stdout, stderr: stderr,
                                   env: env.merge("SPECGUARD_ENDPOINT" => server.endpoint))
                             .run([sink(payload)])

        expect(code).to eq(0)
        expect(server.requests.length).to eq(1)
        expect(server.requests.first.json).to eq(payload)
        expect(server.requests.first.path).to eq("/api/v1/ingest")
        expect(server.requests.first.headers["authorization"]).to eq("Bearer sgk_abc123")
      end
    end

    # Criterion 1, whole: the run refused for a rotated key, replayed after the
    # secret is fixed, reaches the platform. Every line, in order.
    it "delivers every line of a multi-run file" do
      StubIngestEndpoint.run do |server|
        code = described_class.new(stdout: stdout, stderr: stderr,
                                   env: env.merge("SPECGUARD_ENDPOINT" => server.endpoint))
                             .run([sink(run_payload(ci_run_id: "1"),
                                        run_payload(ci_run_id: "2"),
                                        run_payload(ci_run_id: "3"))])

        expect(code).to eq(0)
        expect(server.requests.map { |request| request.json["ci_run_id"] }).to eq(%w[1 2 3])
      end
    end

    it "reports each line by its number, with the run the endpoint said it landed on" do
      StubIngestEndpoint.run(body: '{"test_run_id":"tr_7"}') do |server|
        path = sink(run_payload(ci_run_id: "17442"))
        described_class.new(stdout: stdout, stderr: stderr,
                            env: env.merge("SPECGUARD_ENDPOINT" => server.endpoint)).run([path])

        expect(out).to eq(<<~OUT)
          line 1: accepted — HTTP 202, test_run_id tr_7, ci_run_id 17442
          specguard-ingest: delivered 1 of 1 run from #{path}
        OUT
      end
    end

    # Criterion 4. The 202 body carries no created-versus-updated flag, so the
    # only honest statement about folding is one made from two observations:
    # same run identity out, same run id back. Note what is NOT said — nothing
    # about a line WITHOUT a `ci_run_id`, whose new row is created inside
    # `RunRecorder` where this command cannot see it.
    it "states folding only where two lines observed it" do
      StubIngestEndpoint.run(body: '{"test_run_id":"tr_7"}') do |server|
        path = sink(run_payload(ci_run_id: "17442"), run_payload(ci_run_id: "17442"))
        code = described_class.new(stdout: stdout, stderr: stderr,
                                   env: env.merge("SPECGUARD_ENDPOINT" => server.endpoint)).run([path])

        expect(code).to eq(0)
        expect(out).to eq(<<~OUT)
          line 1: accepted — HTTP 202, test_run_id tr_7, ci_run_id 17442
          line 2: accepted — HTTP 202, test_run_id tr_7, ci_run_id 17442
          specguard-ingest: delivered 2 of 2 runs from #{path}
          specguard-ingest: lines 1, 2 carried ci_run_id 17442 and each came back with test_run_id tr_7 — the endpoint folded them onto one run
        OUT
      end
    end

    it "says a line carried no run identity, and claims nothing further about it" do
      StubIngestEndpoint.run(body: '{"test_run_id":"tr_7"}') do |server|
        described_class.new(stdout: stdout, stderr: stderr,
                            env: env.merge("SPECGUARD_ENDPOINT" => server.endpoint))
                       .run([sink(run_payload(ci_run_id: nil))])

        expect(out).to include("line 1: accepted — HTTP 202, test_run_id tr_7, no ci_run_id")
        expect(out).not_to include("folded")
        expect(out).not_to include("created")
      end
    end

    # Two lines that came back with the same id but went out with DIFFERENT run
    # identities are not evidence of anything the endpoint did on purpose, so
    # no sentence is manufactured for them.
    it "does not claim folding for lines that shared no ci_run_id" do
      StubIngestEndpoint.run(body: '{"test_run_id":"tr_7"}') do |server|
        described_class.new(stdout: stdout, stderr: stderr,
                            env: env.merge("SPECGUARD_ENDPOINT" => server.endpoint))
                       .run([sink(run_payload(ci_run_id: "1"), run_payload(ci_run_id: "2"))])

        expect(out).not_to include("folded")
      end
    end

    # A 202 whose body will not parse is still a 202: the platform stored the
    # run before it wrote the body. The id is reported as unknown rather than
    # the acceptance being downgraded.
    it "reports an unreadable success body as an unknown id, not as a failure" do
      StubIngestEndpoint.run(body: "<html>accepted</html>") do |server|
        code = described_class.new(stdout: stdout, stderr: stderr,
                                   env: env.merge("SPECGUARD_ENDPOINT" => server.endpoint))
                             .run([sink(run_payload)])

        expect(code).to eq(0)
        expect(out).to include("line 1: accepted — HTTP 202, test_run_id (not reported), ci_run_id 17442")
      end
    end
  end

  describe "1 — the endpoint refused a line" do
    it "exits 1 and renders the endpoint's own reasons" do
      body = JSON.generate(
        "message" => "payload is invalid",
        "details" => ["spec 3 (spec/orders_spec.rb:9): line_number is required and must be a positive integer"]
      )

      StubIngestEndpoint.run(status: 400, body: body) do |server|
        path = sink(run_payload)
        code = described_class.new(stdout: stdout, stderr: stderr,
                                   env: env.merge("SPECGUARD_ENDPOINT" => server.endpoint)).run([path])

        expect(code).to eq(1)
        expect(out).to eq(<<~OUT)
          line 1: refused — HTTP 400 — the endpoint rejected the payload — spec 3 (spec/orders_spec.rb:9): line_number is required and must be a positive integer
          specguard-ingest: delivered 0 of 1 run from #{path}; 1 refused
        OUT
      end
    end

    # The endpoint ANSWERED — it read the payload and said no — which is what
    # separates a 1 from a 2 here, and the reason names the credential so the
    # code is never the only thing the operator has to go on.
    it "exits 1 for a 401, naming the key rather than only the number" do
      StubIngestEndpoint.run(status: 401, body: '{"message":"invalid api key"}') do |server|
        code = described_class.new(stdout: stdout, stderr: stderr,
                                   env: env.merge("SPECGUARD_ENDPOINT" => server.endpoint))
                             .run([sink(run_payload)])

        expect(code).to eq(1)
        expect(out).to include("line 1: refused — HTTP 401 — the API key was not accepted — invalid api key")
      end
    end

    # Criterion 3. A file that was only partly accepted must be resumable, and
    # that needs the report to say WHICH lines landed — not how many.
    it "numbers a partly-accepted file line by line" do
      responses = [{ status: 202 }, { status: 400, body: '{"message":"spec 2: outcome is required"}' },
                   { status: 202 }]

      StubIngestEndpoint.run(body: '{"test_run_id":"tr_7"}', responses: responses) do |server|
        path = sink(run_payload(ci_run_id: "a"), run_payload(ci_run_id: "b"), run_payload(ci_run_id: "c"))
        code = described_class.new(stdout: stdout, stderr: stderr,
                                   env: env.merge("SPECGUARD_ENDPOINT" => server.endpoint)).run([path])

        expect(code).to eq(1)
        expect(out).to eq(<<~OUT)
          line 1: accepted — HTTP 202, test_run_id tr_7, ci_run_id a
          line 2: refused — HTTP 400 — the endpoint rejected the payload — spec 2: outcome is required
          line 3: accepted — HTTP 202, test_run_id tr_7, ci_run_id c
          specguard-ingest: delivered 2 of 3 runs from #{path}; 1 refused
        OUT
      end
    end

    it "delivers the lines after a refusal rather than stopping at the first" do
      StubIngestEndpoint.run(responses: [{ status: 400 }, { status: 202 }]) do |server|
        described_class.new(stdout: stdout, stderr: stderr,
                            env: env.merge("SPECGUARD_ENDPOINT" => server.endpoint))
                       .run([sink(run_payload(ci_run_id: "a"), run_payload(ci_run_id: "b"))])

        expect(server.requests.length).to eq(2)
      end
    end
  end

  describe "2 — the tool could not do its job" do
    # The `EXIT_MISUSE` reasoning, verbatim from `cli.rb`: a run that delivered
    # nothing must not report as a content failure.
    context "when delivery is not configured" do
      let(:endpoint) { nil }

      it "exits 2 naming the endpoint, without reading the file" do
        expect(cli.run([sink(run_payload)])).to eq(2)
        expect(err).to eq("specguard-ingest: error: no endpoint is configured (set SPECGUARD_ENDPOINT)\n")
        expect(out).to be_empty
      end

      # Named separately from the endpoint: they fail for different reasons and
      # are fixed in different places.
      it "exits 2 naming the API key when only that is missing" do
        code = described_class.new(stdout: stdout, stderr: stderr,
                                   env: { "SPECGUARD_ENDPOINT" => "https://specguard.example.com" })
                             .run([sink(run_payload)])

        expect(code).to eq(2)
        expect(err).to eq("specguard-ingest: error: no API key is configured (set SPECGUARD_API_KEY)\n")
      end

      # One exit 2 rather than N identical delivery failures: a malformed
      # endpoint is a configuration problem, and reporting it once as one is
      # the difference between "fix this variable" and "the network is flaky".
      it "exits 2 on an endpoint that is not an http(s) URL" do
        code = described_class.new(stdout: stdout, stderr: stderr,
                                   env: env.merge("SPECGUARD_ENDPOINT" => "specguard.example.com"))
                             .run([sink(run_payload, run_payload)])

        expect(code).to eq(2)
        expect(err).to include("endpoint must be an http:// or https:// URL")
      end
    end

    context "when the file cannot be read" do
      let(:endpoint) { "https://specguard.example.com" }

      it "exits 2 on a file that does not exist" do
        expect(cli.run([File.join(@dir, "gone.jsonl")])).to eq(2)
        expect(err).to eq("specguard-ingest: error: no such file: #{File.join(@dir, 'gone.jsonl')}\n")
      end

      it "exits 2 on a directory" do
        expect(cli.run([@dir])).to eq(2)
        expect(err).to eq("specguard-ingest: error: not a file: #{@dir}\n")
      end

      it "exits 2 on a file it may not open" do
        path = sink(run_payload)
        File.chmod(0o000, path)
        skip "running as root, which can read an unreadable file" if File.readable?(path)

        expect(cli.run([path])).to eq(2)
        expect(err).to include("could not read #{path}")
      end
    end

    context "when a line cannot be parsed" do
      it "exits 2, and 2 outranks a refusal on the same file" do
        StubIngestEndpoint.run(status: 400, body: '{"message":"no"}') do |server|
          path = sink(run_payload, "{not json", run_payload)
          code = described_class.new(stdout: stdout, stderr: stderr,
                                     env: env.merge("SPECGUARD_ENDPOINT" => server.endpoint)).run([path])

          expect(code).to eq(2)
          expect(out).to include("line 2: unparseable — could not parse the line as JSON:")
          expect(out).to include("specguard-ingest: delivered 0 of 3 runs from #{path}; " \
                                 "2 refused; 1 could not be parsed")
        end
      end

      # A truncated last line — a sink written by a process that was killed —
      # must not cost the lines before it.
      it "still delivers every line it could parse" do
        StubIngestEndpoint.run do |server|
          code = described_class.new(stdout: stdout, stderr: stderr,
                                     env: env.merge("SPECGUARD_ENDPOINT" => server.endpoint))
                               .run([sink(run_payload(ci_run_id: "a"), run_payload(ci_run_id: "b"),
                                          '{"commit_sha":"abc","spe')])

          expect(code).to eq(2)
          expect(server.requests.map { |request| request.json["ci_run_id"] }).to eq(%w[a b])
        end
      end

      # `JSON.parse` answers a bare `"text"` line with a String and `null` with
      # nil. Neither is a run, and neither may be posted as one.
      [['"a bare string"', "String"], ["null", "NilClass"], ["[1,2]", "Array"], ["42", "Integer"]].each do |line, type|
        it "refuses to post #{line}, which parses but is not a run" do
          StubIngestEndpoint.run do |server|
            code = described_class.new(stdout: stdout, stderr: stderr,
                                       env: env.merge("SPECGUARD_ENDPOINT" => server.endpoint)).run([sink(line)])

            expect(code).to eq(2)
            expect(out).to include("line 1: unparseable — the line is #{type} JSON, and a run is an object")
            expect(server.requests).to be_empty
          end
        end
      end

      # Pointing this command at a binary file is the obvious way to get a line
      # that is not valid UTF-8, and `String#strip` raises on one. Reported as
      # the line problem it is, rather than as an internal error — this tool is
      # not broken, it was handed something that is not a run.
      it "reports a line that is not valid UTF-8 as unparseable, not as a bug in itself" do
        path = File.join(@dir, "binary.jsonl")
        File.open(path, "wb") do |file|
          file.write("#{JSON.generate(run_payload)}\n")
          file.write([0xC3, 0x28, 0xFF, 0x0A].pack("C*"))
        end

        StubIngestEndpoint.run do |server|
          code = described_class.new(stdout: stdout, stderr: stderr,
                                     env: env.merge("SPECGUARD_ENDPOINT" => server.endpoint)).run([path])

          expect(code).to eq(2)
          expect(out).to include("line 2: unparseable — the line is not valid UTF-8, so it cannot be a run")
          expect(err).to be_empty
          # The good line still landed.
          expect(server.requests.length).to eq(1)
        end
      end
    end

    # The endpoint never answered, so no verdict about the content exists.
    # Reporting this as a 1 would be the tool telling an operator their run is
    # bad on the strength of a socket error.
    it "exits 2 when the endpoint could not be reached at all" do
      code = described_class.new(stdout: stdout, stderr: stderr,
                                 env: env.merge("SPECGUARD_ENDPOINT" => dead_endpoint,
                                                "SPECGUARD_TIMEOUT" => "2")).run([sink(run_payload)])

      expect(code).to eq(2)
      expect(out).to include("line 1: not delivered — Errno::ECONNREFUSED")
      expect(out).to include("1 could not be delivered")
    end

    describe "misuse of the command line" do
      let(:endpoint) { "https://specguard.example.com" }

      it "exits 2 with no file given" do
        expect(cli.run([])).to eq(2)
        expect(err).to eq("specguard-ingest: error: no file given — #{described_class::BANNER}\n")
      end

      # A typo'd flag is the likeliest route to a false "the endpoint refused
      # your run": uncaught, OptionParser raises and Ruby exits 1.
      it "exits 2 on an unknown flag rather than letting Ruby's 1 stand" do
        expect(cli.run(["--replaay", "file.jsonl"])).to eq(2)
        expect(err).to eq("specguard-ingest: error: invalid option: --replaay\n")
      end

      it "exits 2 rather than guessing which of two files was meant" do
        expect(cli.run(%w[one.jsonl two.jsonl])).to eq(2)
        expect(err).to include("one file at a time, got 2: one.jsonl, two.jsonl")
      end
    end
  end

  describe "a file with nothing in it to deliver" do
    # `specguard-lint`'s ratified answer to the same shape: the contract has no
    # code for "there was nothing to do", so 0 stands and the warning carries
    # the weight. What must not happen is a silent 0 — "sent nothing" reading
    # as "sent everything".
    it "exits 0 and says so on stderr, rather than reporting a clean run" do
      path = File.join(@dir, "empty.jsonl")
      File.write(path, "")

      expect(cli_for("https://specguard.example.com").run([path])).to eq(0)
      expect(err).to eq("specguard-ingest: warning: #{path} holds no runs to deliver\n")
      expect(out).to be_empty
    end

    it "counts the blank lines it skipped rather than dropping them from the report" do
      StubIngestEndpoint.run do |server|
        path = File.join(@dir, "gappy.jsonl")
        File.write(path, "#{JSON.generate(run_payload)}\n\n\n#{JSON.generate(run_payload)}\n")
        code = described_class.new(stdout: stdout, stderr: stderr,
                                   env: env.merge("SPECGUARD_ENDPOINT" => server.endpoint)).run([path])

        expect(code).to eq(0)
        # Numbered from the FILE, so line 4 in this report is line 4 in an
        # editor — which is the property that makes the report resumable.
        expect(out).to include("line 1: accepted")
        expect(out).to include("line 4: accepted")
        expect(out).to include("delivered 2 of 2 runs from #{path}; 2 blank lines skipped")
      end
    end
  end

  describe "--help and --version" do
    let(:endpoint) { "https://specguard.example.com" }

    it "exits 0 and prints the usage" do
      expect(cli.run(["--help"])).to eq(0)
      expect(out).to include(described_class::BANNER)
    end

    # The second constraint the ticket found, discharged where a user meets it.
    # The sink mixes failed deliveries with ordinary keyless local runs and
    # nothing on the line tells them apart, so a developer must be able to learn
    # BEFORE running this that their laptop's whole history will be sent.
    it "warns in the help that every line is delivered, failures or not" do
      cli.run(["--help"])

      expect(out).to include("EVERY line in <file> is delivered")
      expect(out).to include("when no API key was configured at all")
    end

    it "prints the gem version" do
      expect(cli.run(["--version"])).to eq(0)
      expect(out).to eq("specguard-rspec #{SpecGuard::RSpec::VERSION}\n")
    end
  end

  # #run returns 0, 1 or 2 and never raises — the property `bin/specguard-ingest`
  # depends on, since it turns the return value straight into an exit status.
  describe "the backstop that keeps 1 meaning one thing" do
    it "reports an unexpected internal failure as a 2, in those words" do
      allow(SpecGuard::RSpec::Transport).to receive(:new).and_raise(NotImplementedError, "boom")

      code = described_class.new(stdout: stdout, stderr: stderr,
                                 env: { "SPECGUARD_ENDPOINT" => "https://specguard.example.com",
                                        "SPECGUARD_API_KEY" => "sgk_abc" }).run([sink(run_payload)])

      expect(code).to eq(2)
      expect(err).to eq("specguard-ingest: internal error: NotImplementedError: boom\n")
    end

    it "answers only 0, 1 or 2 across every shape above" do
      expect([described_class::EXIT_OK, described_class::EXIT_REFUSED, described_class::EXIT_MISUSE])
        .to eq([0, 1, 2])
    end
  end

  def cli_for(endpoint)
    described_class.new(stdout: stdout, stderr: stderr,
                        env: { "SPECGUARD_ENDPOINT" => endpoint, "SPECGUARD_API_KEY" => "sgk_abc123" })
  end
end
