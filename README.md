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

Files are **positional** (`specguard-lint spec/order_spec.rb`); there is no `--source` flag —
that belongs to the reference tool, not to this one.

The linter is an independent implementation of the same protocol, and its agreement with the
reference is checked by running the two side by side rather than asserted in a comment:
`tests/parity/run_ruby_parity.sh` in
[open-test-intent](https://github.com/yatfa-ai/open-test-intent) runs `specguard-lint` and the
Go validator over a shared corpus and requires identical findings, ordering and exit codes.
Two read-failure messages are ratified as different there, with the reasons; everything else
matches byte for byte.

## The formatter — `SpecGuard::RSpecFormatter`

An **additive** RSpec formatter: it runs alongside your usual one (`progress`, `documentation`, …)
rather than replacing it, and records every example that finished — annotated or not — as one JSON
object per run, POSTed to SpecGuard (or written to `log/test_results.jsonl` when there is no API
key).

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
```

The two forms are equivalent, and neither needs you to name a human formatter. Additive is meant
literally, in both directions: if you chose one, it is left alone and SpecGuard adds nothing to your
output; if you chose none, you get RSpec's default (`progress`) exactly as you would without this
gem — same dots, same failures, same summary, byte for byte.

That second half is not free, because RSpec installs its default formatter only when *no* formatter
was registered at all — so a gem that registers one silently suppresses it, and a failing suite
prints nothing. SpecGuard restores it on the first notification of the run, once RSpec has finished
deciding. If you want something other than `progress`, name it the usual way (`--format
documentation`, or `config.default_formatter = "doc"`) and that is what you will get, on its own.

Each example contributes its `id`, `spec_file_path`, `file_path`, `line_number`, `name` (the composed
`describe`/`context`/`it` string), `duration`, `outcome`, `status` (`"annotated"` or
`"unannotated"`) and `intent` — the parsed annotation when there is one, `null` when there is not;
the run envelope carries `commit_sha`, `branch` and `duration_seconds`.

`id` is RSpec's own example id — `./spec/orders_spec.rb[1:2]`, the argument that re-runs that one
example — and it is the key that distinguishes examples a coordinate cannot. A table-driven loop
writes its `it` once, so all of its examples share a `line_number`; a shared example group reports
the coordinate of `spec/support/shared.rb` from every file that includes it. `spec_file_path` is the
spec file that actually **ran** the example, which is the same as `file_path` for an ordinary example
and the *including* file for a shared one — so duration-by-file adds up against the file you would
have named, not against a `spec/support/` helper.

> `id` is unique within a run, not stable across refactors: it is positional, so reordering examples
> changes it, exactly as inserting a line changes `line_number`. Matching one test across runs is
> `name` plus file.

`file_path` and `line_number` keep meaning the **definition** site — that is the line the `@intent:`
annotation is read from.

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
# optional — the defaults read the commit, branch, CI run id and shard index
# from whichever provider is running you (GitHub Actions, GitLab CI, CircleCI,
# Buildkite, Jenkins), and when none of them named the commit or the branch,
# ask git directly for both — so a laptop run and a hand-rolled container
# report their checkout too, without being configured to. A detached checkout
# reports no branch rather than the string "HEAD".
# SPECGUARD_COMMIT_SHA / SPECGUARD_BRANCH / SPECGUARD_RUN_ID /
# SPECGUARD_SHARD_ID / SPECGUARD_OUTPUT_PATH override any of it.
#
# Assign a value here only when it is one neither source can know:
SpecGuard::RSpec.configure do |config|
  config.branch = "release/2.0"
end
```

## Shipping the run to SpecGuard

Set an API key and an endpoint and the run is POSTed to
`<endpoint>/api/v1/ingest` — once per process, as a single request (see
[If you shard your suite](#if-you-shard-your-suite) for what happens when there
is more than one process):

```bash
export SPECGUARD_ENDPOINT=https://specguard.example.com
export SPECGUARD_API_KEY=…          # from your repository's settings
export SPECGUARD_TIMEOUT=10         # optional; seconds, applied to connect and read
```

```ruby
# ...or in Ruby, if you would rather not use the environment
SpecGuard::RSpec.configure do |config|
  config.endpoint = "https://specguard.example.com"
  config.api_key  = ENV["SPECGUARD_API_KEY"]
  config.timeout  = 10
end
```

**The API key is the switch.** With no key nothing is sent anywhere and the run
is written to `log/test_results.jsonl` exactly as before — so local development
needs no opt-out, and a fork with no secret configured behaves like a laptop
rather than like a broken build.

**A failed delivery is never silent, and never lost.** If the endpoint refuses
the run (a `401` from a rotated key, a `400`, a `500`) or cannot be reached at
all (connection refused, DNS failure, timeout), the formatter prints **one**
line to stderr naming the status or the error, and writes the payload to
`log/test_results.jsonl` so the run can be replayed later:

```
SpecGuard: could not deliver test telemetry (HTTP 401 — the API key was not
accepted). Falling back to log/test_results.jsonl; the test run is unaffected.
```

There are **no retries**, and the whole delivery is bounded by `timeout`
(10 seconds by default, against `Net::HTTP`'s own 60): telemetry is explicitly
allowed to be lost, and a retry would only double what a hung endpoint can cost
your CI run.

It **never blocks CI.** RSpec does not sandbox formatters — an exception raised
in one escapes the runner and takes RSpec's own exit code with it — so every
hook rescues, warns once on stderr, and leaves the exit status to your suite
alone. A non-2xx response gets the same treatment: `Net::HTTP` returns those as
ordinary values rather than raising, so they are checked for explicitly instead
of being left to a `rescue` that would never see them.

### If you shard your suite

`parallel_tests`, Knapsack and a CI matrix all run the suite as several
processes, and each one loads this formatter and POSTs its own slice. The run id
is what tells SpecGuard those POSTs are **one run**: shards that share it are
accumulated onto a single record, so a 20,000-example suite reports a 20,000
denominator instead of one record per shard holding a quarter of it — and a
quarter is what the dashboard showed before, attributed to the right commit,
with nothing to mark it as partial.

Every supported provider publishes an id for the build (`GITHUB_RUN_ID`,
`CI_PIPELINE_ID`, `CIRCLE_WORKFLOW_ID`, `BUILDKITE_BUILD_ID`, `BUILD_TAG`), so a
sharded job on any of them needs no configuration. If you shard somewhere else,
export one yourself — any value that every shard of the run shares and no other
run repeats:

```bash
export SPECGUARD_RUN_ID="$MY_CI_BUILD_ID"
```

Unset is not an error. A run with no id is treated as a run of its own, which is
exactly right for `bundle exec rspec` on a laptop. A genuinely different run — a
nightly, a later push — gets a different id from its provider and stays a
separate record, which is why the commit alone cannot do this job.

#### Re-runs, and why each shard also names itself

A CI run id does **not** change when you re-run the build. GitHub's own wording
for `GITHUB_RUN_ID` is *"This number does not change if you re-run the workflow
run"*; Buildkite retries a job inside the same `BUILDKITE_BUILD_ID` and GitLab
inside the same `CI_PIPELINE_ID`. That is the behaviour SpecGuard wants — press
"re-run failed jobs" on a sharded suite and only the failed shards run again, so
they need to land back on the run they came from rather than forming a new run
holding a fifth of the suite.

For that to be right, a shard has to be able to *replace* its own earlier
numbers instead of adding to them, which means naming itself. SpecGuard reads
the shard index your runner already exports:

| Runner | Variable |
| --- | --- |
| `parallel_tests` | `TEST_ENV_NUMBER` (its blank first process is read as shard `1`) |
| GitLab `parallel:`, Knapsack Pro | `CI_NODE_INDEX` |
| CircleCI `parallelism:` | `CIRCLE_NODE_INDEX` |
| Buildkite `parallelism:` | `BUILDKITE_PARALLEL_JOB` |

**GitHub Actions `matrix:` is the one that needs a line of config.** It exports
no per-leg index — `GITHUB_JOB` is the job's id in your YAML and is identical
across every leg — so set it from the matrix value:

```yaml
strategy:
  matrix:
    shard: [1, 2, 3, 4]
steps:
  - run: bundle exec rspec
    env:
      SPECGUARD_SHARD_ID: ${{ matrix.shard }}
```

The value only has to be unique *within one run*; it is never compared across
runs. Do the same if you nest — `parallel_tests` inside a matrix leg repeats
`TEST_ENV_NUMBER` across legs, so give `SPECGUARD_SHARD_ID` something that
composes both.

Leaving it unset is not an error and does not lose the slice: an unnamed shard
is still counted into the run. What it cannot do is be recognised on a second
delivery, so if that shard is retried its numbers are added again rather than
replacing what was there. If your suite shards and you re-run it, name the
shards.
