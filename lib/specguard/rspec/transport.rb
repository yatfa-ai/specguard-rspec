# frozen_string_literal: true

require "json"
require "net/http"
require "uri"

require_relative "configuration"
require_relative "version"

module SpecGuard
  module RSpec
    # The one HTTP call this gem makes: `POST <endpoint>/api/v1/ingest`,
    # carrying a whole run.
    #
    # == Why this returns a result instead of raising
    #
    # {SpecGuard::RSpecFormatter}'s never-block-CI guard is a `rescue` around
    # each hook, and a `rescue` is structurally blind to the failure that
    # matters most here: `Net::HTTP` hands back `Net::HTTPUnauthorized` as an
    # ordinary return value. A wrong API key therefore raises nothing, warns
    # nothing and logs nothing — the run's telemetry disappears in complete
    # silence, which is precisely the outcome the client-gem spec's "if the API
    # key is wrong … it logs a warning to stderr" forbids.
    #
    # So the two failure families are made the same *shape* rather than left to
    # two different mechanisms: {#deliver} answers a {Result} for a non-2xx
    # response and a {Result} for a raised exception, and the caller has one
    # thing to check. Nothing escapes this class except `Interrupt`,
    # `SignalException` and `SystemExit` — Ctrl-C must stay Ctrl-C.
    #
    # == One request, uncompressed
    #
    # The run goes in a single POST with an identity-encoded body, and that is a
    # decision about the *platform*, not a shortcut:
    #
    #   * `Api::V1::IngestsController#create` is an unconditional
    #     `test_runs.create!` per request, and `Ingest::Payload` derives
    #     `total_specs_count` from the specs of *that* request. Splitting a run
    #     across N POSTs would produce N `TestRun` rows with a split
    #     denominator, corrupting the headline annotated-ratio metric.
    #   * The platform does not decompress request bodies, so a gzipped body
    #     reaches the JSON parser as bytes and fails.
    #
    # Both are cross-repo changes to make deliberately on the platform side
    # first. Until then, one request is the only shape that lands correctly.
    class Transport
      # `config/routes.rb` mounts `post "ingest"` under the `/api/v1` scope.
      # Part of the platform's contract, so it is not configurable — the
      # `endpoint` setting is the installation's address and nothing more.
      PATH = "/api/v1/ingest"
      CONTENT_TYPE = "application/json"
      USER_AGENT = "specguard-rspec/#{SpecGuard::RSpec::VERSION}"

      # What the ingest endpoint said, in the one form the caller has to handle.
      #
      # `outcome` is one of:
      #
      #   :success   a 2xx. `code` carries it (202 in the happy path).
      #   :rejected  a non-2xx. `code` carries it; nothing was raised.
      #   :failed    an exception was raised. `error` carries it.
      Result = Struct.new(:outcome, :code, :error, keyword_init: true) do
        # The status codes worth spelling out, because each implies a different
        # thing for the reader to *do*. A 401 means "rotate or fix the key"; a
        # 400 means "the payload this gem built was refused", which is a bug
        # report and not a credentials problem. Printing a bare number would
        # leave a CI operator to guess which of the two they are looking at.
        ADVICE = {
          400 => "the endpoint rejected the payload",
          401 => "the API key was not accepted",
          403 => "this API key may not write to that repository",
          404 => "no ingest endpoint at that URL — check SPECGUARD_ENDPOINT",
          413 => "the payload was too large for the endpoint",
          429 => "rate limited by the endpoint"
        }.freeze

        def success? = outcome == :success

        # A single clause naming what went wrong, for the one stderr line a run
        # is allowed. `nil` on success, because there is nothing to say.
        #
        # @return [String, nil]
        def reason
          case outcome
          when :success then nil
          when :rejected then [+"HTTP #{code}", ADVICE[code]].compact.join(" — ")
          else "#{error.class}: #{error.message}"
          end
        end
      end

      # @param endpoint [String, nil] the installation's base URL. Any trailing
      #   slashes are dropped; a path prefix is preserved, so an installation
      #   behind `https://tools.example.com/specguard` works.
      # @param api_key [String, nil] sent verbatim as a Bearer token.
      # @param timeout [Numeric, String, nil] seconds. Anything that is not a
      #   positive finite number falls back to the default rather than raising:
      #   a typo in `SPECGUARD_TIMEOUT` must not be able to fail a suite.
      def initialize(endpoint:, api_key:, timeout: Configuration::DEFAULT_TIMEOUT_SECONDS)
        @endpoint = endpoint
        @api_key = api_key
        @timeout = sanitize_timeout(timeout)
      end

      attr_reader :timeout

      # Where this transport would POST.
      #
      # @return [URI::HTTP]
      # @raise [ArgumentError] when the endpoint is missing or is not an
      #   http(s) URL. Raised rather than returned because {#deliver} converts
      #   it into a {Result} like every other failure, and a caller asking for
      #   the URI directly wants to know.
      def uri
        @uri ||= build_uri
      end

      # @param payload [Hash] the run, as {SpecGuard::RSpecFormatter#payload}
      #   assembles it. Sent as-is: its key names are already the platform's
      #   ingest contract, and reshaping it here would put the wire format two
      #   files away from the code that decides it.
      # @return [Result] never nil, never raised through.
      def deliver(payload)
        response = post(JSON.generate(payload))
        code = response.code.to_i

        return Result.new(outcome: :success, code: code) if response.is_a?(Net::HTTPSuccess)

        Result.new(outcome: :rejected, code: code)
      rescue ScriptError, StandardError => e
        # Connection refused, DNS failure, TLS failure, open/read timeout, a
        # malformed endpoint — one family, one shape. `ScriptError` is in the
        # list for the same reason the formatter's guard names it: an autoload
        # blowing up under `net/http` is not a `StandardError`, and a bare
        # rescue would let it escape and take the suite's exit code with it.
        Result.new(outcome: :failed, error: e)
      end

      private

      def post(body)
        target = uri

        http = Net::HTTP.new(target.host, target.port)
        http.use_ssl = target.scheme == "https"
        # All three, not just the two the spec names. A 20k-example run is a
        # ~6 MiB body, so a peer that accepts the connection and then stops
        # reading would hang in the *write* — the same unbounded wait, reached
        # by a different door.
        http.open_timeout = @timeout
        http.read_timeout = @timeout
        http.write_timeout = @timeout

        http.start { |connection| connection.request(build_request(target, body)) }
      end

      def build_request(target, body)
        request = Net::HTTP::Post.new(target.request_uri)
        # `Api::BaseController#bearer_token` matches /\ABearer\s+(?<token>.+)\z/i.
        request["Authorization"] = "Bearer #{@api_key}"
        request["Content-Type"] = CONTENT_TYPE
        request["Accept"] = CONTENT_TYPE
        request["User-Agent"] = USER_AGENT
        request.body = body
        request
      end

      def build_uri
        base = @endpoint.to_s.strip
        raise ArgumentError, "no endpoint is configured (set SPECGUARD_ENDPOINT)" if base.empty?

        parsed = URI.parse(base.sub(%r{/+\z}, "") + PATH)
        # `URI::HTTPS < URI::HTTP`, so this admits both and rejects the
        # scheme-less `specguard.example.com` that `URI.parse` happily returns
        # as a `URI::Generic` with a nil host — which `Net::HTTP` would then
        # try to connect to.
        raise ArgumentError, "endpoint must be an http:// or https:// URL, got #{base.inspect}" unless
          parsed.is_a?(URI::HTTP) && !parsed.host.to_s.empty?

        parsed
      end

      def sanitize_timeout(value)
        parsed = Float(value, exception: false)
        return Configuration::DEFAULT_TIMEOUT_SECONDS unless parsed&.finite? && parsed.positive?

        parsed
      end
    end
  end
end
