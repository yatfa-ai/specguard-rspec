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

An **additive** RSpec formatter that collects every example's `@intent` at end-of-run and POSTs it
to SpecGuard's `/api/v1/ingest`. It runs alongside your usual formatter (`progress`,
`documentation`, …) and **never blocks CI** — on any failure (network, bad key, timeout) it logs
to stderr and exits silently. When no API key is set, it writes `log/test_results.jsonl` locally
instead of POSTing.

```ruby
# spec/spec_helper.rb
require "specguard/rspec_formatter"
RSpec.configure do |config|
  config.add_formatter(SpecGuard::RSpecFormatter)
end
```

**Status:** specification stage.
