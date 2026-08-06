# frozen_string_literal: true

require "specguard/rspec/formatter"

# Criterion 6: the formatter's settings, their ENV defaults, and the promise
# that nothing here can be the reason a suite fails.
RSpec.describe SpecGuard::RSpec::Configuration do
  describe "defaults, seeded from the environment" do
    # `env:` is injected rather than mutating the process's own ENV: these
    # examples would otherwise be order-dependent with anything else that reads
    # a variable, and would behave differently inside a GitHub Actions job
    # (where GITHUB_SHA really is set) than on a laptop.
    subject(:configuration) { described_class.new(env: env) }

    let(:env) { {} }

    context "with nothing set at all" do
      it "reports an unknown commit rather than raising" do
        expect(configuration.commit_sha).to be_nil
      end

      it "reports an unknown branch rather than raising" do
        expect(configuration.branch).to be_nil
      end

      # The one field that cannot be nil: with no path there is no sink, and a
      # run that captured everything and wrote it nowhere is the failure mode
      # this whole slice exists to avoid.
      it "still knows where to write" do
        expect(configuration.output_path).to eq("log/test_results.jsonl")
      end
    end

    context "in a GitHub Actions job" do
      let(:env) { { "GITHUB_SHA" => "9f8e7d6", "GITHUB_REF_NAME" => "main" } }

      it "takes the commit and branch from the job's own variables" do
        expect(configuration).to have_attributes(commit_sha: "9f8e7d6", branch: "main")
      end
    end

    context "when the project overrides the provider" do
      let(:env) do
        {
          "SPECGUARD_COMMIT_SHA" => "deadbeef",
          "GITHUB_SHA" => "9f8e7d6",
          "SPECGUARD_BRANCH" => "release/2.0",
          "GITHUB_REF_NAME" => "main",
          "SPECGUARD_OUTPUT_PATH" => "tmp/specguard.jsonl"
        }
      end

      it "prefers the SPECGUARD_ variable over the provider's" do
        expect(configuration).to have_attributes(commit_sha: "deadbeef", branch: "release/2.0")
      end

      it "honours a configured output path" do
        expect(configuration.output_path).to eq("tmp/specguard.jsonl")
      end
    end

    # CI providers routinely export "" for a variable that does not apply to
    # the current event — a pull_request build has no GITHUB_REF_NAME branch in
    # some configurations. Taking that literally would put an empty string in
    # the envelope, which reads as a real answer and is not one.
    context "when a variable is exported but blank" do
      let(:env) { { "SPECGUARD_COMMIT_SHA" => "  ", "GITHUB_SHA" => "9f8e7d6", "SPECGUARD_OUTPUT_PATH" => "" } }

      it "treats blank as unset and falls through to the next source" do
        expect(configuration.commit_sha).to eq("9f8e7d6")
      end

      it "falls back to the default path rather than writing to \"\"" do
        expect(configuration.output_path).to eq("log/test_results.jsonl")
      end
    end

    it "strips surrounding whitespace, which a shell here-doc adds easily" do
      configuration = described_class.new(env: { "SPECGUARD_BRANCH" => "  main\n" })

      expect(configuration.branch).to eq("main")
    end
  end

  # Deliberately absent until the transport slice. Naming them here would
  # advertise a capability that does not exist: nothing in this slice speaks
  # HTTP, and a project that set an `endpoint` would reasonably expect it to be
  # used.
  it "does not yet pretend to know about an endpoint, an api key or a timeout" do
    expect(described_class.instance_methods(false)).to contain_exactly(
      :commit_sha, :commit_sha=, :branch, :branch=, :output_path, :output_path=
    )
  end
end

RSpec.describe SpecGuard::RSpec do
  after { described_class.reset_configuration! }

  describe ".configure" do
    it "hands the block the configuration to set" do
      described_class.configure { |config| config.branch = "feature/telemetry" }

      expect(described_class.configuration.branch).to eq("feature/telemetry")
    end

    it "returns the configuration, so it can be read without a block" do
      expect(described_class.configure).to equal(described_class.configuration)
    end

    it "does not raise when called with no block at all" do
      expect { described_class.configure }.not_to raise_error
    end

    # One configuration per process. Two objects would mean a `spec_helper.rb`
    # configuring one while the formatter reads the other — the settings would
    # simply be ignored, silently.
    it "keeps configuring the same object across calls" do
      described_class.configure { |config| config.commit_sha = "abc" }
      described_class.configure { |config| config.branch = "main" }

      expect(described_class.configuration).to have_attributes(commit_sha: "abc", branch: "main")
    end
  end

  describe ".reset_configuration!" do
    it "drops the memoized configuration so the next read re-seeds from ENV" do
      described_class.configure { |config| config.branch = "throwaway" }

      expect { described_class.reset_configuration! }
        .to change { described_class.configuration.branch }.from("throwaway")
    end
  end
end
