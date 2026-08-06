# frozen_string_literal: true

module SpecGuard
  module RSpec
    # What {SpecGuard::RSpecFormatter} needs to know about the run it is
    # watching: which checkout produced it, and where to put what was captured.
    #
    # == Why the environment is the default source
    #
    # `commit_sha` and `branch` are facts about the *checkout*, not about the
    # suite, and every CI provider already publishes them. Reading them from
    # ENV means the common case — a GitHub Actions job — needs no configuration
    # at all, and the escape hatch stays open for everyone else:
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
    # == What is deliberately absent
    #
    # No `endpoint`, no `api_key`, no `timeout`. Nothing in this slice speaks
    # HTTP: names, durations and outcomes are not yet stored by the platform's
    # ingest endpoint, so POSTing them today would be a cheerful `202` into a
    # void. Transport lands with the third slice of SPGD-116, and adding its
    # settings here early would advertise a capability that does not exist.
    class Configuration
      # Relative to the working directory the suite was started from, which is
      # the project root for every normal `bundle exec rspec` invocation.
      DEFAULT_OUTPUT_PATH = "log/test_results.jsonl"

      # Checked in order, first non-blank wins. The `SPECGUARD_`-prefixed name
      # comes first everywhere so a project can always override whatever its CI
      # provider decided to export.
      COMMIT_SHA_KEYS = %w[SPECGUARD_COMMIT_SHA GITHUB_SHA].freeze
      # `GITHUB_REF_NAME` is the short name (`main`), not the full ref
      # (`refs/heads/main`) that `GITHUB_REF` carries.
      BRANCH_KEYS = %w[SPECGUARD_BRANCH GITHUB_REF_NAME].freeze
      OUTPUT_PATH_KEYS = %w[SPECGUARD_OUTPUT_PATH].freeze

      # The commit the suite ran against. `nil` when nothing said.
      attr_accessor :commit_sha
      # The branch the suite ran on. `nil` when nothing said.
      attr_accessor :branch
      # Where the run's JSON payload is appended, one object per line.
      attr_accessor :output_path

      # @param env [#[]] the environment to seed defaults from. Injectable so
      #   the mapping can be tested without mutating the process's own ENV.
      def initialize(env: ENV)
        @commit_sha = first_present(env, COMMIT_SHA_KEYS)
        @branch = first_present(env, BRANCH_KEYS)
        @output_path = first_present(env, OUTPUT_PATH_KEYS) || DEFAULT_OUTPUT_PATH
      end

      private

      def first_present(env, keys)
        keys.each do |key|
          value = env[key].to_s.strip
          return value unless value.empty?
        end

        nil
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
