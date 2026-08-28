# frozen_string_literal: true

require_relative "lib/specguard/rspec/version"

Gem::Specification.new do |spec|
  spec.name = "specguard-rspec"
  spec.version = SpecGuard::RSpec::VERSION
  spec.authors = ["specguard Agent"]
  spec.email = ["specguard-agent@noreply.yatfa.com"]

  spec.summary = "RSpec formatter and @intent annotation linter for SpecGuard."
  spec.description = "SpecGuard's Ruby client. Ships an additive RSpec formatter that posts " \
                     "test-run telemetry to SpecGuard's ingest endpoint, a CLI linter " \
                     "(specguard-lint) that validates OpenTestIntent @intent annotations in " \
                     "*_spec.rb files, and a replayer (specguard-ingest) that re-delivers a run " \
                     "the formatter saved when the endpoint could not be reached. Telemetry " \
                     "never blocks CI; the linter blocks only on malformed annotations."
  spec.homepage = "https://github.com/yatfa-ai/specguard-rspec"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.2.0"

  spec.metadata["homepage_uri"] = spec.homepage
  spec.metadata["bug_tracker_uri"] = "#{spec.homepage}/issues"

  # Specify which files should be added to the gem when it is released.
  # The `git ls-files -z` loads the files in the RubyGem that have been added into git.
  gemspec = File.basename(__FILE__)
  spec.files = IO.popen(%w[git ls-files -z], chdir: __dir__, err: IO::NULL) do |ls|
    ls.readlines("\x0", chomp: true).reject do |f|
      (f == gemspec) ||
        f.start_with?(*%w[Gemfile .gitignore .rspec spec/ sig/ bin/console bin/setup])
    end
  end
  spec.bindir = "bin"
  # Two commands. `specguard-lint` validates annotations; `specguard-ingest`
  # replays a saved `log/test_results.jsonl` back through the ingest endpoint,
  # which is what makes the formatter's fallback file recoverable rather than
  # only written.
  spec.executables = %w[specguard-lint specguard-ingest]
  spec.require_paths = ["lib"]

  # `json` is a default gem, so without this line the parser follows whatever
  # the host Ruby happens to ship — and it is not a stable target. 2.9 alone
  # closed a nesting off-by-one, changed how an unpaired high surrogate is
  # decoded, and reworded its parse errors. The linter classifies a malformed
  # annotation by asking this parser, so a silent swap underneath changes what
  # `specguard-lint` REPORTS, on a machine nobody upgraded on purpose.
  # Depending on it explicitly makes the parser a version we chose.
  spec.add_dependency "json", "~> 2.21"

  # For more information and examples about making a new gem, check out our
  # guide at: https://bundler.io/guides/creating_gem.html
end
