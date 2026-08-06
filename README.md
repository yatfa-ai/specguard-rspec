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
`describe`/`context`/`it` string), `duration`, `outcome`, `status` (`"annotated"` or
`"unannotated"`) and `intent` — the parsed annotation when there is one, `null` when there is not;
the run envelope carries `commit_sha`, `branch` and `duration_seconds`.

An example counts as **annotated** when an `@intent:` sits on its `it` line, or on the comment line
immediately above it:

```ruby
# @intent: { entity: "Order", action: "refund", behavior: "restores stock levels on refund", layer: "unit" }
it "restores stock on refund" do

it "surfaces the decline reason" do # @intent: { entity: "Order", action: "checkout", ... }
```

One line of lookback, no more — and a trailing annotation belongs to its own example only, never to
the one on the next line.

> **A malformed or schema-invalid annotation is recorded as `unannotated`, with a `null` intent, and
> the formatter says nothing about it.** That is deliberate: telemetry must never block CI, and the
> platform validates a run's payload as a whole — so shipping one bad annotation would cost the
> *entire run* its telemetry rather than one row its metadata. `specguard-lint` is the half of this
> gem that tells you about a bad annotation, loudly, with exit code `1`. Run it in CI and the
> formatter never has anything to hide.

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

**Status:** captures every example to the local JSONL sink, with its annotation resolved. The POST
to SpecGuard's `/api/v1/ingest` is still to come.
