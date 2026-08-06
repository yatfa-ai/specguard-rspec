# frozen_string_literal: true

require "specguard/rspec/transport"

require_relative "../../support/stub_ingest_endpoint"

# The one HTTP call this gem makes, against a real socket.
#
# Everything here is about the two things a `rescue` around a POST cannot see:
# a response that arrived and said no, and a request that never arrived at all.
# `Net::HTTP` returns `Net::HTTPUnauthorized` as an ordinary value, so a wrong
# API key raises nothing — and the formatter's never-block-CI guard is a
# `rescue`. Making both families the same {Result} shape is what gives the
# caller one thing to check.
RSpec.describe SpecGuard::RSpec::Transport do
  let(:payload) do
    {
      "commit_sha" => "0d4a1f2c9b8e7d6a5f4c3b2a1908f7e6d5c4b3a2",
      "branch" => "main",
      "duration_seconds" => 1.25,
      "specs" => [
        { "file_path" => "spec/orders_spec.rb", "line_number" => 4, "name" => "Order checks out",
          "duration" => 0.01, "outcome" => "passed", "status" => "unannotated", "intent" => nil }
      ]
    }
  end

  def transport_to(server, api_key: "sgk_abc123", timeout: 5)
    described_class.new(endpoint: server.endpoint, api_key: api_key, timeout: timeout)
  end

  # Criterion 1.
  describe "the request it puts on the wire" do
    subject(:request) { captured }

    # One round trip, read back from the server's own record of what arrived.
    # Memoized rather than taken in a `before(:context)` hook: a constant or an
    # ivar shared across examples here would have to be assigned at the *lexical*
    # scope, which inside an `RSpec.describe` block is top level.
    let(:captured) do
      StubIngestEndpoint.run do |server|
        transport_to(server).deliver(payload)
        server.requests.first
      end
    end

    it "POSTs" do
      expect(request.verb).to eq("POST")
    end

    # `config/routes.rb` mounts `post "ingest"` inside the `/api/v1` scope. The
    # client owns the host; the path is the platform's and is not configurable.
    it "posts to /api/v1/ingest, which the endpoint setting does not include" do
      expect(request.path).to eq("/api/v1/ingest")
    end

    # `Api::BaseController#bearer_token` matches /\ABearer\s+(?<token>.+)\z/i
    # and 401s on anything else — including the `Token ` and bare-key forms an
    # implementation might reasonably have guessed at.
    it "authenticates with a Bearer token in the form the platform parses" do
      expect(request.headers["authorization"]).to eq("Bearer sgk_abc123")
    end

    it "declares a JSON body, without which Rails parses nothing" do
      expect(request.headers["content-type"]).to eq("application/json")
    end

    it "identifies itself, so the platform can tell its clients apart" do
      expect(request.headers["user-agent"]).to eq("specguard-rspec/#{SpecGuard::RSpec::VERSION}")
    end

    # The body is `#payload` verbatim. Reshaping it in transport would put the
    # wire format two files away from the code that decides it.
    it "sends the payload unchanged, key for key" do
      expect(request.json).to eq(payload)
    end

    # FIND 3: the platform does not decompress request bodies, so a gzipped one
    # reaches the JSON parser as bytes and 400s. Identity is not laziness here,
    # it is the only encoding that lands.
    it "sends the body uncompressed, because the platform cannot decompress one" do
      expect(request.headers["content-encoding"]).to be_nil
    end
  end

  it "sends the whole run in a single request" do
    StubIngestEndpoint.run do |server|
      transport_to(server).deliver(payload.merge("specs" => Array.new(50) { payload["specs"].first }))

      expect(server.requests.length).to eq(1)
    end
  end

  describe "a 202, which is what the ingest endpoint answers on success" do
    it "reports success, carrying the code" do
      StubIngestEndpoint.run(status: 202) do |server|
        result = transport_to(server).deliver(payload)

        expect(result).to have_attributes(success?: true, outcome: :success, code: 202)
      end
    end

    it "has nothing to warn about" do
      StubIngestEndpoint.run(status: 202) do |server|
        expect(transport_to(server).deliver(payload).reason).to be_nil
      end
    end

    it "accepts any 2xx rather than only the exact code it expects today" do
      StubIngestEndpoint.run(status: 200) do |server|
        expect(transport_to(server).deliver(payload)).to be_success
      end
    end
  end

  # FIND 2, at its source. None of these raise, which is why a `rescue` alone
  # loses them all without a trace.
  describe "a non-2xx response" do
    {
      400 => "the endpoint rejected the payload",
      401 => "the API key was not accepted",
      403 => "this API key may not write to that repository",
      404 => "no ingest endpoint at that URL",
      429 => "rate limited",
      500 => nil
    }.each do |status, advice|
      context "when the endpoint answers #{status}" do
        it "reports a rejection rather than a success" do
          StubIngestEndpoint.run(status: status) do |server|
            expect(transport_to(server).deliver(payload))
              .to have_attributes(success?: false, outcome: :rejected, code: status)
          end
        end

        # The number is the non-negotiable part: a 401 means "rotate the key"
        # and a 400 means "this gem built a body the platform refused", which
        # are different people's problems.
        it "names the status in something a CI operator can read" do
          StubIngestEndpoint.run(status: status) do |server|
            reason = transport_to(server).deliver(payload).reason

            expect(reason).to include("HTTP #{status}")
            expect(reason).to include(advice) if advice
          end
        end
      end
    end

    it "does not raise, so nothing above it can be relying on one" do
      StubIngestEndpoint.run(status: 500) do |server|
        expect { transport_to(server).deliver(payload) }.not_to raise_error
      end
    end
  end

  # Criterion 4. One shape for the whole family, so the caller has one branch.
  describe "a request that never gets an answer" do
    it "reports a failure when the connection is refused" do
      # Bound, then closed: the port is guaranteed to have been free, and
      # nothing is listening on it now.
      server = TCPServer.new("127.0.0.1", 0)
      port = server.addr[1]
      server.close

      result = described_class.new(endpoint: "http://127.0.0.1:#{port}", api_key: "k", timeout: 2)
                              .deliver(payload)

      expect(result).to have_attributes(success?: false, outcome: :failed)
      expect(result.error).to be_a(SystemCallError)
    end

    it "reports a failure when the host does not resolve" do
      result = described_class
               .new(endpoint: "http://specguard.invalid", api_key: "k", timeout: 2)
               .deliver(payload)

      expect(result).to have_attributes(success?: false, outcome: :failed)
      expect(result.reason).to be_a(String)
    end

    # Criterion 6, at the unit level: the budget is the budget, and a peer that
    # accepts the connection and then says nothing is the shape that would
    # otherwise sit there for `Net::HTTP`'s stock 60 seconds.
    it "gives up on a silent endpoint within the configured budget" do
      StubIngestEndpoint.run(hang: true) do |server|
        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        result = transport_to(server, timeout: 1).deliver(payload)
        elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

        expect(result.outcome).to eq(:failed)
        expect(result.error).to be_a(Net::ReadTimeout)
        expect(elapsed).to be < 5
      end
    end
  end

  # A misconfiguration is delivered as a failure like any other, rather than as
  # an exception the formatter's guard would have to catch separately.
  describe "an endpoint that is not a URL" do
    ["", "   ", nil].each do |value|
      it "reports a failure rather than posting to #{value.inspect}" do
        result = described_class.new(endpoint: value, api_key: "k", timeout: 1).deliver(payload)

        expect(result.outcome).to eq(:failed)
        expect(result.reason).to include("no endpoint is configured")
      end
    end

    # `URI.parse` returns a `URI::Generic` with a nil host for this rather than
    # raising, and `Net::HTTP` would then try to connect to nowhere.
    it "rejects a bare host with no scheme" do
      result = described_class.new(endpoint: "specguard.example.com", api_key: "k", timeout: 1)
                              .deliver(payload)

      expect(result.outcome).to eq(:failed)
      expect(result.reason).to include("http:// or https://")
    end

    it "rejects a scheme it cannot speak" do
      result = described_class.new(endpoint: "ftp://specguard.example.com", api_key: "k", timeout: 1)
                              .deliver(payload)

      expect(result.outcome).to eq(:failed)
    end
  end

  describe "#uri" do
    it "appends the platform's path to the configured installation" do
      transport = described_class.new(endpoint: "https://specguard.example.com", api_key: "k")

      expect(transport.uri.to_s).to eq("https://specguard.example.com/api/v1/ingest")
    end

    # A trailing slash is what a copy-paste out of a browser's address bar
    # gives you, and `"https://host/" + "/api/v1/ingest"` is a 404.
    it "does not double the slash when the endpoint has a trailing one" do
      transport = described_class.new(endpoint: "https://specguard.example.com///", api_key: "k")

      expect(transport.uri.to_s).to eq("https://specguard.example.com/api/v1/ingest")
    end

    # SpecGuard is self-hostable, and a self-hosted one may well sit behind a
    # path on a shared hostname.
    it "keeps a path prefix, for an installation mounted under one" do
      transport = described_class.new(endpoint: "https://tools.example.com/specguard", api_key: "k")

      expect(transport.uri.to_s).to eq("https://tools.example.com/specguard/api/v1/ingest")
    end

    it "uses TLS for an https endpoint and not for an http one" do
      expect(described_class.new(endpoint: "https://x.example.com", api_key: "k").uri.scheme).to eq("https")
      expect(described_class.new(endpoint: "http://x.example.com", api_key: "k").uri.scheme).to eq("http")
    end
  end

  describe "the timeout budget" do
    def timeout_for(value) = described_class.new(endpoint: "https://x.example.com", api_key: "k",
                                                 timeout: value).timeout

    it "defaults to the configuration's, not Net::HTTP's 60 seconds" do
      expect(described_class.new(endpoint: "https://x.example.com", api_key: "k").timeout).to eq(10)
    end

    it "honours a configured budget" do
      expect(timeout_for(2.5)).to eq(2.5)
    end

    it "accepts the string a configured ENV variable arrives as" do
      expect(timeout_for("3")).to eq(3.0)
    end

    # A `0` here means "time out immediately" to Net::HTTP: a typo would turn
    # into a run that silently never delivers anything.
    [0, -1, "ten", nil, Float::INFINITY, Float::NAN].each do |value|
      it "falls back to the default rather than trusting #{value.inspect}" do
        expect(timeout_for(value)).to eq(10)
      end
    end
  end

  # The never-block-CI contract, seen from inside the transport: it must not be
  # possible for this class to end a suite, and it must still be possible to
  # stop one with Ctrl-C.
  describe "what it refuses to let escape" do
    it "swallows a ScriptError, which a bare rescue would miss" do
      allow(Net::HTTP).to receive(:new).and_raise(NotImplementedError, "nope")

      result = described_class.new(endpoint: "https://x.example.com", api_key: "k").deliver(payload)

      expect(result).to have_attributes(outcome: :failed)
      expect(result.reason).to include("NotImplementedError")
    end

    it "swallows a payload that will not serialize" do
      unserializable = { "specs" => [Object.new] }
      allow(JSON).to receive(:generate).and_raise(JSON::GeneratorError, "cannot serialize")

      expect(described_class.new(endpoint: "https://x.example.com", api_key: "k").deliver(unserializable))
        .to have_attributes(outcome: :failed)
    end

    # Ctrl-C must stay Ctrl-C. Reporting an interrupt as "delivery failed" is
    # its own small lie, and would make a long suite harder to stop.
    it "does NOT swallow an interrupt" do
      allow(Net::HTTP).to receive(:new).and_raise(Interrupt)

      expect { described_class.new(endpoint: "https://x.example.com", api_key: "k").deliver(payload) }
        .to raise_error(Interrupt)
    end
  end
end
