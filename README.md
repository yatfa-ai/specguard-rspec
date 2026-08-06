# specguard-rspec

> The Ruby client for [SpecGuard](https://github.com/yatfa-ai/specguard): an RSpec formatter that ships test-run telemetry,
> and a CLI linter that validates `@intent` annotations.

Two independent tools, one dependency — the [OpenTestIntent](https://github.com/yatfa-ai/open-test-intent) annotation format.

## Install

```ruby
# Gemfile
group :test do
  gem "specguard-rspec", require: false
end
```

## The linter — `specguard-lint`

Validates `# @intent:` annotations in changed (or all) `*_spec.rb` files against the OpenTestIntent
JSON Schema. Exits `1` on a malformed annotation; **never** fails on a *missing* one (adoption is
opt-in and gradual).

```bash
bundle exec specguard-lint --changed   # CI mode: only files in the current diff
bundle exec specguard-lint             # one-off audit: every *_spec.rb
```

## The formatter — `SpecGuard::RSpecFormatter`

An **additive** RSpec formatter: it runs alongside your usual one (`progress`, `documentation`, …)
rather than replacing it, and records every example that finished — annotated or not — as one JSON
object per run in `log/test_results.jsonl`.

```ruby
# spec/spec_helper.rb
require "specguard/rspec/formatter"
RSpec.configure do |config|
  config.add_formatter(SpecGuard::RSpecFormatter)
end
```

```
# ...or in .rspec — the --require is not optional, RSpec cannot guess this path
--require specguard/rspec/formatter
--format SpecGuard::RSpecFormatter
--format progress
```

Each example contributes its `file_path`, `line_number`, `name` (the composed
`describe`/`context`/`it` string), `duration` and `outcome`; the run envelope carries `commit_sha`,
`branch` and `duration_seconds`.

```ruby
# optional — the defaults read GITHUB_SHA / GITHUB_REF_NAME, or SPECGUARD_COMMIT_SHA /
# SPECGUARD_BRANCH / SPECGUARD_OUTPUT_PATH
SpecGuard::RSpec.configure do |config|
  config.commit_sha = `git rev-parse HEAD`.strip
end
```

It **never blocks CI.** RSpec does not sandbox formatters — an exception raised in one escapes the
runner and takes RSpec's own exit code with it — so every hook rescues, warns once on stderr, and
leaves the exit status to your suite alone.

**Status:** captures to the local JSONL sink. Annotation discovery and the POST to SpecGuard's
`/api/v1/ingest` are still to come.
