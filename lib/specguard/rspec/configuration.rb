# frozen_string_literal: true

module SpecGuard
  module RSpec
    # The commit the checkout is sitting on, asked of git directly.
    #
    # This is the *last* resort, consulted only when no environment variable
    # named the commit. It exists because `commit_sha` is the one envelope field
    # the platform refuses a run without (`Ingest::Payload#validate_commit_sha`
    # rejects a blank one and the whole POST comes back 400, every example
    # discarded), so a run that cannot name its commit is a run whose telemetry
    # is lost entirely — not one with a gap in it.
    #
    # Three properties, all load-bearing:
    #
    #   * It never raises. `git` may not be installed at all, in which case
    #     `IO.popen` raises `Errno::ENOENT` before a subprocess ever exists.
    #   * It never prints. `git rev-parse HEAD` outside a repository writes
    #     "fatal: not a git repository" to stderr, and a telemetry tool that
    #     graffitis somebody's CI log with a git error has already failed.
    #   * It answers once per process. The result is memoized because a
    #     subprocess is expensive relative to everything else here, and the
    #     answer cannot change mid-run.
    module GitCheckout
      COMMAND = %w[git rev-parse HEAD].freeze

      class << self
        # @return [String, nil] the checked-out commit, or nil for any reason
        #   at all — no git, no repository, an empty repository, a broken HEAD.
        def commit_sha
          return @commit_sha if defined?(@commit_sha)

          @commit_sha = resolve
        end

        # Drop the memoized answer. For tests, and for the rare caller that
        # changes directory into a different checkout mid-process.
        #
        # @return [void]
        def reset!
          remove_instance_variable(:@commit_sha) if defined?(@commit_sha)
          nil
        end

        private

        def resolve
          # `err: IO::NULL` is the "never prints" half: outside a repository
          # `git rev-parse` writes "fatal: not a git repository" to stderr, and
          # the exit status is the only part of that we want.
          output = IO.popen(COMMAND, err: IO::NULL, &:read)
          return nil unless $?&.success? # rubocop:disable Style/SpecialGlobalVars

          value = output.to_s.strip
          value.empty? ? nil : value
        rescue ScriptError, StandardError
          # `Errno::ENOENT` (no git binary) is the common one; the broad rescue
          # is deliberate, because there is no failure here worth a raise.
          nil
        end
      end
    end

    # What {SpecGuard::RSpecFormatter} needs to know about the run it is
    # watching: which checkout produced it, and where to send what was captured.
    #
    # == Why the environment is the default source
    #
    # `commit_sha` and `branch` are facts about the *checkout*, not about the
    # suite, and every CI provider already publishes them. Reading them from
    # ENV means the common case — a CI job on any of the five major providers —
    # needs no configuration at all, and the escape hatch stays open for
    # everyone else:
    #
    #   SpecGuard::RSpec.configure do |config|
    #     config.commit_sha = `git rev-parse HEAD`.strip
    #     config.branch     = `git rev-parse --abbrev-ref HEAD`.strip
    #   end
    #
    # An explicitly assigned value always wins; the ENV names are only
    # consulted to seed the defaults.
    #
    # == Why an unset value is nil rather than an error
    #
    # Nothing here may ever be the reason a test run fails (see
    # {SpecGuard::RSpecFormatter}'s never-block-CI contract). Somebody running
    # `bundle exec rspec` on a laptop has no `GITHUB_SHA`, and that is not a
    # misconfiguration to shout about — it is a run whose envelope honestly
    # records "unknown commit". A blank or whitespace-only variable is treated
    # the same as an unset one, because CI providers routinely export `""` for
    # a variable that does not apply to the current event.
    #
    # == Transport, and what an unset `api_key` means
    #
    # `endpoint`, `api_key` and `timeout` configure the POST to SpecGuard's
    # ingest endpoint. `api_key` is the switch: set it and the run is delivered
    # over HTTP, leave it unset and the run is appended to `output_path` exactly
    # as before. Local development is therefore the default, and it needs no
    # opt-out — which is the whole reason the switch is the credential rather
    # than a separate `enabled` flag nobody would remember to turn off.
    #
    # There is deliberately **no default endpoint**. SpecGuard is self-hostable
    # and there is no address that is right for everybody; guessing one would
    # mean a misconfigured project POSTing its test names to whatever happens to
    # answer at that name.
    class Configuration
      # Relative to the working directory the suite was started from, which is
      # the project root for every normal `bundle exec rspec` invocation.
      DEFAULT_OUTPUT_PATH = "log/test_results.jsonl"

      # Applied to opening the connection and to reading the response.
      #
      # `Net::HTTP`'s own defaults are 60s each, which is up to two minutes
      # added to every CI run against a hung endpoint — squarely against the
      # roadmap's "a 20,000-example run must not be meaningfully slowed". Ten
      # seconds is the number the client-gem spec settles on, and it is the
      # whole budget: there are **no retries**, because a retry doubles the
      # worst case for telemetry that is explicitly allowed to be lost.
      DEFAULT_TIMEOUT_SECONDS = 10

      # Checked in order, first non-blank wins. The `SPECGUARD_`-prefixed name
      # comes first everywhere so a project can always override whatever its CI
      # provider decided to export.
      #
      # The provider list is not decoration. `commit_sha` is the one field the
      # platform rejects a run over, so a list that only knew `GITHUB_SHA` meant
      # every GitLab, CircleCI, Buildkite and Jenkins run 400ing as a matter of
      # course — the *default* outcome on four of the five providers this gem is
      # likely to meet.
      COMMIT_SHA_KEYS = %w[
        SPECGUARD_COMMIT_SHA
        GITHUB_SHA
        CI_COMMIT_SHA
        CIRCLE_SHA1
        BUILDKITE_COMMIT
        GIT_COMMIT
      ].freeze

      # The same providers, in the same order. `GITHUB_REF_NAME` is the short
      # name (`main`), not the full ref (`refs/heads/main`) that `GITHUB_REF`
      # carries; Jenkins's `GIT_BRANCH` is passed through as it comes
      # (`origin/main` on many setups), because `branch` is a free-form string
      # to the platform and inventing a normalization here would be this gem
      # guessing at somebody's ref layout.
      BRANCH_KEYS = %w[
        SPECGUARD_BRANCH
        GITHUB_REF_NAME
        CI_COMMIT_REF_NAME
        CIRCLE_BRANCH
        BUILDKITE_BRANCH
        GIT_BRANCH
      ].freeze

      # The id the CI provider gave the *build*, which every shard of a
      # sharded run shares and no second run of the same commit repeats.
      #
      # This is the field that makes a 20,000-example suite land as one run.
      # Nobody runs a suite that size in a single process: under
      # `parallel_tests`, Knapsack or a CI matrix each shard loads this
      # formatter and POSTs its own slice, and every shard carries the same
      # `commit_sha` and `branch` — so the platform had nothing to tell four
      # shards of one run apart from four separate runs, and recorded four
      # `TestRun` rows each holding a quarter of the denominator. Annotations
      # tend to cluster in whatever area a team is currently working on rather
      # than spreading evenly across shards, so the headline ratio then moved
      # from re-run to re-run without the suite changing at all.
      #
      # `commit_sha` cannot stand in for it: a re-run and a nightly of the same
      # commit are genuinely two runs and must stay two rows.
      #
      # Same providers in the same order as above, and the same "unset is nil,
      # never an error" rule — a laptop run has none of these, and the platform
      # treats a run with no id as its own run, which is exactly right.
      #
      # The requirement on whatever a provider exports is only this: every shard
      # of one run reads the same value, and no other run reads it. A project
      # whose CI layout does not satisfy that for the variable below — Jenkins
      # `BUILD_TAG` interpolates `JOB_NAME`, which some matrix layouts vary per
      # axis — sets `SPECGUARD_RUN_ID` itself, which wins over all of them.
      RUN_ID_KEYS = %w[
        SPECGUARD_RUN_ID
        GITHUB_RUN_ID
        CI_PIPELINE_ID
        CIRCLE_WORKFLOW_ID
        BUILDKITE_BUILD_ID
        BUILD_TAG
      ].freeze

      OUTPUT_PATH_KEYS = %w[SPECGUARD_OUTPUT_PATH].freeze
      ENDPOINT_KEYS = %w[SPECGUARD_ENDPOINT].freeze
      API_KEY_KEYS = %w[SPECGUARD_API_KEY].freeze
      TIMEOUT_KEYS = %w[SPECGUARD_TIMEOUT].freeze

      # The commit the suite ran against. `nil` when nothing said.
      attr_accessor :commit_sha
      # The branch the suite ran on. `nil` when nothing said.
      attr_accessor :branch
      # The CI provider's id for the build this process is one shard of.
      # `nil` when nothing said, which is how a laptop run spells "I am my own
      # run". See {RUN_ID_KEYS}.
      attr_accessor :run_id
      # Where the run's JSON payload is appended, one object per line — the
      # local sink when there is no API key, and the fallback when delivery
      # fails.
      attr_accessor :output_path
      # The SpecGuard installation to POST to, scheme and host only:
      # `https://specguard.example.com`. The `/api/v1/ingest` path is the
      # platform's contract, not a setting. `nil` when nothing said.
      attr_accessor :endpoint
      # The repository's SpecGuard API key. Present means "deliver over HTTP".
      #
      # Deliberately **not** format-checked. The platform mints `sgk_`-prefixed
      # keys today; a client that gated on that prefix would start rejecting
      # valid keys the day the platform rotated it, from a version of the gem
      # nobody can retroactively fix. Send whatever is configured and let a 401
      # be the answer.
      attr_accessor :api_key
      # Seconds, applied to opening the connection and to reading the response.
      attr_accessor :timeout

      # @param env [#[]] the environment to seed defaults from. Injectable so
      #   the mapping can be tested without mutating the process's own ENV.
      # @param git [#commit_sha] the checkout to fall back to when no variable
      #   named the commit. Injectable for the same reason, and so a test does
      #   not silently pick up the sha of whatever repository it runs in.
      def initialize(env: ENV, git: GitCheckout)
        @commit_sha = first_present(env, COMMIT_SHA_KEYS) || blank_to_nil(git.commit_sha)
        @branch = first_present(env, BRANCH_KEYS)
        @run_id = first_present(env, RUN_ID_KEYS)
        @output_path = first_present(env, OUTPUT_PATH_KEYS) || DEFAULT_OUTPUT_PATH
        @endpoint = first_present(env, ENDPOINT_KEYS)
        @api_key = first_present(env, API_KEY_KEYS)
        @timeout = seconds(first_present(env, TIMEOUT_KEYS)) || DEFAULT_TIMEOUT_SECONDS
      end

      private

      def first_present(env, keys)
        keys.each do |key|
          value = env[key].to_s.strip
          return value unless value.empty?
        end

        nil
      end

      def blank_to_nil(value)
        string = value.to_s.strip
        string.empty? ? nil : string
      end

      # A garbage `SPECGUARD_TIMEOUT` falls back to the default rather than
      # raising or, worse, being coerced to `0` by `String#to_i` — which
      # `Net::HTTP` reads as "time out immediately" and would turn a typo into
      # a run that never delivers anything.
      def seconds(value)
        parsed = Float(value, exception: false)
        return nil unless parsed&.finite? && parsed.positive?

        parsed
      end
    end

    class << self
      # The process-wide formatter configuration.
      #
      # Built on first use rather than at load time so that a `configure` block
      # in a `spec_helper.rb` and a variable exported by a CI job describe the
      # same object regardless of which the interpreter reached first.
      #
      # @return [Configuration]
      def configuration
        @configuration ||= Configuration.new
      end

      # Configure the formatter.
      #
      #   SpecGuard::RSpec.configure do |config|
      #     config.branch = "release/2.0"
      #   end
      #
      # @yieldparam configuration [Configuration]
      # @return [Configuration] the configuration, block or no block
      def configure
        yield configuration if block_given?
        configuration
      end

      # Drop the memoized configuration so the next read re-seeds from ENV.
      # Exists for tests, and for the rare caller that changes the environment
      # after this file was loaded.
      #
      # @return [void]
      def reset_configuration!
        @configuration = nil
      end
    end
  end
end
