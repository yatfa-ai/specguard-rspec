# frozen_string_literal: true

require "tmpdir"
require "specguard/rspec/formatter"

# Criterion 6: the formatter's settings, their ENV defaults, and the promise
# that nothing here can be the reason a suite fails.
RSpec.describe SpecGuard::RSpec::Configuration do
  # Never the real checkout. `commit_sha` now falls back to `git rev-parse
  # HEAD`, and a spec that let that through would be asserting against whatever
  # commit the suite happens to be running on — green on a laptop, and green for
  # the wrong reason.
  let(:no_git) { object_double(SpecGuard::RSpec::GitCheckout, commit_sha: nil) }

  describe "defaults, seeded from the environment" do
    # `env:` is injected rather than mutating the process's own ENV: these
    # examples would otherwise be order-dependent with anything else that reads
    # a variable, and would behave differently inside a GitHub Actions job
    # (where GITHUB_SHA really is set) than on a laptop.
    subject(:configuration) { described_class.new(env: env, git: no_git) }

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

      # Transport is opt-in, and stays off until somebody supplies a
      # credential. A default endpoint would be worse than none: SpecGuard is
      # self-hostable, so there is no address that is right for everybody, and
      # guessing one means a misconfigured project POSTing its test names to
      # whatever answers at that name.
      it "speaks to nobody until an endpoint and a key are supplied" do
        expect(configuration).to have_attributes(endpoint: nil, api_key: nil)
      end

      it "still has a timeout budget, so the default is never Net::HTTP's 60s" do
        expect(configuration.timeout).to eq(10)
      end
    end

    context "in a GitHub Actions job" do
      let(:env) { { "GITHUB_SHA" => "9f8e7d6", "GITHUB_REF_NAME" => "main" } }

      it "takes the commit and branch from the job's own variables" do
        expect(configuration).to have_attributes(commit_sha: "9f8e7d6", branch: "main")
      end
    end

    # Criterion 5. `commit_sha` is the one envelope field the platform refuses a
    # run over (`Ingest::Payload#validate_commit_sha` → 400, every example
    # discarded), so a key list that only knew GitHub meant the *default*
    # outcome on four of the five providers this gem is likely to meet was total
    # telemetry loss. Asserted per provider, so a failure names the one that
    # regressed rather than moving a count.
    {
      "GitLab CI" => { sha: "CI_COMMIT_SHA", branch: "CI_COMMIT_REF_NAME" },
      "CircleCI" => { sha: "CIRCLE_SHA1", branch: "CIRCLE_BRANCH" },
      "Buildkite" => { sha: "BUILDKITE_COMMIT", branch: "BUILDKITE_BRANCH" },
      "Jenkins" => { sha: "GIT_COMMIT", branch: "GIT_BRANCH" }
    }.each do |provider, keys|
      context "on #{provider}" do
        let(:env) { { keys[:sha] => "9f8e7d6", keys[:branch] => "release/2.0" } }

        it "resolves the commit from #{keys[:sha]}" do
          expect(configuration.commit_sha).to eq("9f8e7d6")
        end

        it "resolves the branch from #{keys[:branch]}" do
          expect(configuration.branch).to eq("release/2.0")
        end
      end
    end

    # GitHub's variables win over the rest not because GitHub is special but
    # because a fixed order is the only thing that makes the answer predictable
    # when a job exports several — a GitLab runner inside a GitHub-mirrored
    # repo, say. `SPECGUARD_` is first everywhere, which is the override that
    # settles any of it.
    context "when several providers' variables are present at once" do
      let(:env) { { "GITHUB_SHA" => "github", "CI_COMMIT_SHA" => "gitlab", "CIRCLE_SHA1" => "circle" } }

      it "resolves them in the documented order rather than at random" do
        expect(configuration.commit_sha).to eq("github")
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

    describe "the transport settings" do
      let(:env) do
        {
          "SPECGUARD_ENDPOINT" => "https://specguard.example.com",
          "SPECGUARD_API_KEY" => "sgk_abc123",
          "SPECGUARD_TIMEOUT" => "2.5"
        }
      end

      it "reads the endpoint, the key and the timeout from the environment" do
        expect(configuration).to have_attributes(
          endpoint: "https://specguard.example.com",
          api_key: "sgk_abc123",
          timeout: 2.5
        )
      end

      # `String#to_i` reads "ten" as 0, and Net::HTTP reads a 0 timeout as
      # "give up immediately" — so the naive coercion turns a typo into a run
      # that silently never delivers anything, which is the exact failure this
      # slice exists to remove.
      ["ten", "0", "-5", "  ", "NaN"].each do |value|
        it "falls back to the default rather than trusting #{value.inspect}" do
          configuration = described_class.new(env: env.merge("SPECGUARD_TIMEOUT" => value), git: no_git)

          expect(configuration.timeout).to eq(10)
        end
      end

      it "does not raise on a nonsense timeout, whatever else it does" do
        expect { described_class.new(env: { "SPECGUARD_TIMEOUT" => "ten" }, git: no_git) }
          .not_to raise_error
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

    # A blank `SPECGUARD_API_KEY` is how a CI job spells "this fork has no
    # secret". Read literally it is a *present* key, which would send the run
    # to a guaranteed 401 instead of the local sink.
    context "when the API key is exported but blank" do
      let(:env) { { "SPECGUARD_API_KEY" => "", "SPECGUARD_ENDPOINT" => "https://specguard.example.com" } }

      it "treats it as no key at all" do
        expect(configuration.api_key).to be_nil
      end
    end

    it "strips surrounding whitespace, which a shell here-doc adds easily" do
      configuration = described_class.new(env: { "SPECGUARD_BRANCH" => "  main\n" }, git: no_git)

      expect(configuration.branch).to eq("main")
    end
  end

  # Criterion 5's tail: the run nobody's CI provider named. Without this, a
  # laptop run, a hand-rolled container and any provider not on the list above
  # all produce a blank `commit_sha` — which the platform rejects outright.
  describe "the git fallback" do
    let(:git) { object_double(SpecGuard::RSpec::GitCheckout, commit_sha: "cafebabe") }

    it "asks the checkout when no variable named the commit" do
      expect(described_class.new(env: {}, git: git).commit_sha).to eq("cafebabe")
    end

    # The subprocess is the expensive thing here, and it is pure loss when a CI
    # provider already published the answer.
    it "does not ask when a variable already answered" do
      described_class.new(env: { "GITHUB_SHA" => "9f8e7d6" }, git: git)

      expect(git).not_to have_received(:commit_sha)
    end

    it "reports an unknown commit when git has no answer either" do
      expect(described_class.new(env: {}, git: no_git).commit_sha).to be_nil
    end

    it "treats a blank answer from git as no answer" do
      blank = object_double(SpecGuard::RSpec::GitCheckout, commit_sha: "  \n")

      expect(described_class.new(env: {}, git: blank).commit_sha).to be_nil
    end
  end
end

# The fallback's own contract, exercised against the real `git` binary. Its
# three properties are all failure-shaped, which is why they are pinned here
# rather than left to the injected double every other example uses.
RSpec.describe SpecGuard::RSpec::GitCheckout do
  before { described_class.reset! }

  after { described_class.reset! }

  it "reports the commit this checkout is on" do
    expect(described_class.commit_sha).to match(/\A[0-9a-f]{40}\z/)
  end

  it "agrees with git itself" do
    expect(described_class.commit_sha).to eq(`git rev-parse HEAD`.strip)
  end

  # One subprocess per process, not one per read. `Configuration.new` is built
  # lazily and rebuilt by every `reset_configuration!`, so an unmemoized answer
  # would fork git on a schedule nobody controls.
  it "asks git once and remembers the answer" do
    allow(IO).to receive(:popen).and_call_original

    3.times { described_class.commit_sha }

    expect(IO).to have_received(:popen).once
  end

  it "remembers a nil answer too, rather than retrying a question that failed" do
    allow(IO).to receive(:popen).and_raise(Errno::ENOENT, "git")

    3.times { described_class.commit_sha }

    expect(described_class.commit_sha).to be_nil
    expect(IO).to have_received(:popen).once
  end

  describe "outside a git checkout" do
    around do |example|
      Dir.mktmpdir { |dir| Dir.chdir(dir) { example.run } }
    end

    # Not a `git init`'d directory: mktmpdir lands under /tmp, which is not
    # inside this repository, so `git rev-parse` really does fail here.
    it "answers nil rather than raising" do
      expect(described_class.commit_sha).to be_nil
    end

    # "fatal: not a git repository (or any of the parent directories): .git" is
    # git's, and a telemetry tool that graffitis somebody's CI log with it has
    # already failed. Captured at the file-descriptor level because the child
    # process writes to fd 2 directly — reassigning `$stderr` would not see it.
    it "says nothing at all on stderr while failing" do
      expect { described_class.commit_sha }.not_to output.to_stderr_from_any_process
    end
  end

  # `Errno::ENOENT` is raised by `IO.popen` itself, before any child exists —
  # the shape a `$?.success?` check alone would sail straight past.
  it "answers nil when there is no git binary at all" do
    allow(IO).to receive(:popen).and_raise(Errno::ENOENT, "No such file or directory - git")

    expect(described_class.commit_sha).to be_nil
  end

  it "answers nil when the lookup blows up in a way a bare rescue would miss" do
    allow(IO).to receive(:popen).and_raise(NotImplementedError, "nope")

    expect(described_class.commit_sha).to be_nil
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
