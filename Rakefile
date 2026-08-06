# frozen_string_literal: true

require "bundler/gem_tasks"
require "rspec/core/rake_task"

# The fixtures under spec/fixtures/ are linter *input* that happens to be named
# `*_spec.rb` — exactly what RSpec's default pattern loads. `.rspec` excludes
# them, and that is the source of truth for a bare `rspec` run.
#
# The rake task has to repeat it. RSpec::Core::RakeTask always puts an explicit
# `--pattern` on the command line, and a command-line `--pattern` discards the
# `--exclude-pattern` that came from `.rspec` — so the stock task loads the
# fixtures as examples and the suite dies with
# "cannot load such file -- rails_helper". Passing the exclusion on the command
# line too is what makes the two invocations agree. (Clearing `t.pattern`
# instead does not work: the task then passes an empty argument and matches
# nothing.)
#
# Keep this in step with `.rspec` — `rake` and `rspec` must select the same
# files. spec/spec_helper.rb fails the suite loudly if a fixture ever does get
# loaded as an example.
RSpec::Core::RakeTask.new(:spec) do |t|
  t.rspec_opts = %(--exclude-pattern "spec/fixtures/**/*_spec.rb")
end

# `rake` with no arguments used to do nothing at all, which made it a useless
# CI entrypoint. It now means "run the suite".
task default: %i[spec]
