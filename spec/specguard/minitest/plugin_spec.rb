# frozen_string_literal: true

require "json"
require "open3"
require "socket"
require "tmpdir"

# The end-to-end chain the unit specs in reporter_spec.rb deliberately avoid:
# a real `minitest` run in a real child process, the plugin attached the way
# Minitest attaches plugins, and one POST landing on a real local server with
# the platform's field names in it. The fixture deliberately contains a
# failure and a skip so the outcome mapping is proven over the wire, not only
# in memory — and the child exits non-zero because of the failure, which is
# itself load-bearing: telemetry must ship from a red run, because a red run
# is the run you most want recorded.
RSpec.describe "the minitest plugin" do
  ROOT = File.expand_path("../../..", __dir__)
  FIXTURE = File.join(ROOT, "spec", "fixtures", "minitest", "telemetry_probe_test.rb")
  LIB = File.join(ROOT, "lib")

  # A one-request HTTP server: reads the request line, headers and
  # Content-Length body, answers 202 with a body shaped like the platform's,
  # closes. Deliberately no threading — exactly one POST is expected, and a
  # second connection hanging forever is a better failure than a swallowed
  # one.
  class CaptureServer
    attr_reader :requests

    def initialize
      @server = TCPServer.new("127.0.0.1", 0)
      @requests = []
    end

    def url = "http://127.0.0.1:#{@server.addr[1]}"

    # Accepts in a loop, not once: Net::HTTP legitimately re-connects when
    # reading a response fails mid-way (a retry the transport cannot and
    # should not suppress), and a one-shot server turns that retry into a
    # connection refused that reads like the plugin's fault. `drain` bounds
    # the loop to what a single run can legitimately produce.
    def drain(limit = 4)
      limit.times { read_request }
    rescue Errno::ECONNREFUSED, IOError
      # The child is gone and no further connection is coming — an accept
      # that never arrives is the loop's ordinary end, not a failure.
      nil
    end

    def read_request
      socket = @server.accept
      request_line = socket.gets("\r\n")
      headers = {}
      while (line = socket.gets("\r\n")) && line != "\r\n"
        key, value = line.split(":", 2)
        headers[key.strip.downcase] = value.strip
      end
      body = socket.read(headers["content-length"].to_i)
      @requests << { line: request_line, headers: headers, body: body }
      socket.write("HTTP/1.1 202 Accepted\r\nContent-Type: application/json\r\n" \
                   "Content-Length: 21\r\nConnection: close\r\n\r\n" \
                   '{"test_run_id":"probe"}')
      socket.close
    end

    def close
      @server.close unless @server.closed?
    end
  end

  it "attaches, runs the suite, and posts one envelope with the platform's field names" do
    server = CaptureServer.new
    begin
      Dir.mktmpdir do |dir|
        env = {
          "SPECGUARD_ENDPOINT" => server.url,
          "SPECGUARD_API_KEY" => "sgk_probe",
          "SPECGUARD_COMMIT_SHA" => "2" * 40,
          "SPECGUARD_BRANCH" => "probe-branch",
          "SPECGUARD_RUN_ID" => "probe-run",
          "SPECGUARD_OUTPUT_PATH" => File.join(dir, "should_not_be_needed.jsonl")
        }

        # The child POSTs before it exits, and a socket with no accept() yet
        # only buffers the request — so the read MUST run concurrently with
        # the child, or parent and child wait on each other forever: the
        # parent on the child's exit, the child on this very accept.
        # The child runs on plain Ruby with `-I lib`, not under this
        # process's Bundler: a child inheriting RUBYOPT would fight it over
        # which minitest to activate (the newest installed versus the one this
        # suite's lockfile pins), and die before running a single test — a
        # failure that has nothing to do with the plugin under test.
        child_env = ENV.to_h.except("RUBYOPT", "BUNDLE_GEMFILE", "BUNDLER_VERSION", "RUBYLIB").merge!(env)

        reader = Thread.new { server.drain }
        # `-e` runs with the fixture as ARGV[0]: attach the plugin explicitly
        # (the `extensions` push is what Minitest's own discovery does for a
        # gem it found — proved separately below), then load the suite, whose
        # `minitest/autorun` runs it at exit.
        _out, err, status = Open3.capture3(
          child_env,
          RbConfig.ruby, "-I", LIB,
          # Order matters: minitest first, the plugin second. Minitest's own
          # discovery always loads plugins after minitest itself; loading the
          # plugin file first would open a bare `module Minitest` with nothing
          # in it, and the `-e` below would speak to that shell of a module.
          "-rminitest", "-rminitest/specguard_plugin",
          "-e", 'Minitest.extensions << "specguard"; load ARGV[0]',
          FIXTURE
        )
        reader.join(10)

        # The fixture fails one test, so the child is red — and the POST must
        # have happened anyway, before the exit code was settled.
        expect(status.exitstatus).to eq(1)
        expect(err).not_to include("SpecGuard:")

        request = server.requests.first
        expect(request).not_to be_nil
        expect(request[:line]).to start_with("POST /api/v1/ingest")
        expect(request[:headers]["authorization"]).to eq("Bearer sgk_probe")
        expect(request[:headers]["user-agent"]).to start_with("specguard-ruby/")

        envelope = JSON.parse(request[:body])
        expect(envelope).to match(
          "commit_sha" => "2" * 40,
          "branch" => "probe-branch",
          "ci_run_id" => "probe-run",
          "shard_id" => nil,
          "duration_seconds" => a_kind_of(Numeric),
          "specs" => array_including(
            hash_including("name" => "TelemetryProbeTest#test_passes", "outcome" => "passed"),
            hash_including("name" => "TelemetryProbeTest#test_fails", "outcome" => "failed"),
            hash_including("name" => "TelemetryProbeTest#test_skips", "outcome" => "pending")
          )
        )
        expect(File.exist?(env["SPECGUARD_OUTPUT_PATH"])).to be(false)
      end
    ensure
      server.close
    end
  end

  it "is discoverable by Minitest's plugin mechanism when the gem is on the load path" do
    # `-I lib` puts the gem's lib directory in front of Ruby's, which is the
    # same thing Bundler does for a path dependency. Gem.find_files is how
    # Minitest discovers plugins; if our file were named or placed wrongly,
    # this is the assertion that says so without spawning a child.
    out, _err, _status = Open3.capture3(
      ENV.to_h.except("RUBYOPT", "BUNDLE_GEMFILE", "BUNDLER_VERSION", "RUBYLIB"),
      RbConfig.ruby, "-I", LIB,
      "-e", 'puts Gem.find_files("minitest/*_plugin.rb")'
    )
    expect(out).to include("specguard_plugin.rb")
  end
end
