# frozen_string_literal: true

require_relative "lib/specguard/rspec/version"

Gem::Specification.new do |spec|
  spec.name = "specguard-rspec"
  spec.version = SpecGuard::RSpec::VERSION
  spec.authors = ["specguard Agent"]
  spec.email = ["specguard-agent@noreply.yatfa.com"]

  spec.summary = "RSpec formatter and @intent annotation linter for SpecGuard."
  spec.description = "SpecGuard's Ruby client. Ships an additive RSpec formatter that posts " \
                     "test-run telemetry to SpecGuard's ingest endpoint, and a CLI linter " \
                     "(specguard-lint) that validates OpenTestIntent @intent annotations in " \
                     "*_spec.rb files. Telemetry never blocks CI; the linter blocks only on " \
                     "malformed annotations. This release contains the buildable gem skeleton."
  spec.homepage = "https://github.com/yatfa-ai/specguard-rspec"
  # NOTE: no `spec.license` is declared. The project has not chosen a license
  # yet (no LICENSE file exists in any SpecGuard repo, and neither the README
  # nor the Client Gem spec names one). Declaring a license here without
  # shipping the corresponding license text would advertise a rights grant
  # that does not exist. Set this — and add the matching LICENSE file — once
  # licensing is decided.
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
  spec.executables = ["specguard-lint"]
  spec.require_paths = ["lib"]

  # The linter validates each @intent payload against the vendored
  # OpenTestIntent v1 schema. Pinned to 2.5 on purpose: the linter renders its
  # own reason lines from json_schemer's *structured* error fields (`type`,
  # `data_pointer`, `details.missing_keys`) precisely so a gem bump cannot
  # silently drift the wording — but the set of `type` values it dispatches on
  # is still 2.x API surface, so a major bump wants a look.
  spec.add_dependency "json_schemer", "~> 2.5"

  # For more information and examples about making a new gem, check out our
  # guide at: https://bundler.io/guides/creating_gem.html
end
