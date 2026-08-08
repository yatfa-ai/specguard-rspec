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
A handful of differences are ratified as such there, each with its reason and each asserted to
*still* differ; everything else matches byte for byte. They are the same ones described under
the backend below — two read failures, a parse-failure message, and one that is not about
wording at all.

### Optional: the Go validator as a backend

Set `SPECGUARD_VALIDATE_INTENT` to a `validate-intent` binary and `specguard-lint` will hand the
selected files to it (`--source --json`) instead of validating them in Ruby, then render the same
report from its findings:

```bash
SPECGUARD_VALIDATE_INTENT=/path/to/validate-intent bundle exec specguard-lint --changed
```

**Off by default, and unset means unchanged.** The binary is not shipped with this gem and is not
published anywhere yet, so the Ruby path stays the default and stays supported — this is for people
who already build or vendor the validator and would rather run one implementation than two. A blank
value counts as unset.

What it does *not* change: the selection, the report format, or the summary-line format. What it
*can* change is narrower than an earlier version of this section claimed, and the difference is
worth stating precisely rather than reassuringly.

For every payload both JSON parsers accept, the two backends agree completely: the same finding
against the same file at the same line, the same classification, the same counts and the same exit
code. **The messages in the table below differ in their trailing text only** — the rows *are* the
enumeration, not a sample of it, and each is asserted in both directions, so closing one fails the
suite rather than leaving a stale claim here — in
`spec/specguard/rspec/validator_backend_spec.rb` and in the parity harness above:

| input | Ruby path | Go backend |
|---|---|---|
| a payload that is still not JSON after normalisation | `unexpected character: 'unit' at line 1 column 102` | `Expecting value: line 1 column 102 (char 101)` |
| a file that is not valid UTF-8 | `invalid UTF-8 byte sequence` | the validator's own decoder message |
| a path that does not exist | `No such file or directory @ rb_sysopen - …` | `no file at this path` |
| a path that is not a regular file | `Is a directory @ io_fread - …` | `no file at this path` |

The first row is the one you are most likely to actually see: `parse` is one of the three things
the linter reports, and **every** malformed-JSON annotation renders differently under the backend.
The Ruby path interpolates Ruby's `JSON::ParserError`; the validator reproduces CPython's `json`
diagnostic, and the backend passes that through unaltered rather than inventing a third spelling.
Both agree on which annotation broke, and on the line and column — only the prose moves. The other
rows are read failures and need an unreadable path to reach at all.

#### The difference that is not about wording

The two JSON parsers do not accept the same language. CPython's `json` — which the validator
reproduces deliberately — accepts three things Ruby's `JSON.parse` refuses:

1. the non-finite literals `NaN`, `Infinity` and `-Infinity`;
2. a high surrogate escape (`\ud800`–`\udbff`) not followed by a low one;
3. nesting deeper than Ruby's `max_nesting: 100` default.

That list is exhaustive, and it was derived rather than guessed: 89,108 documents, including every
one of the 65,536 single `\uXXXX` escapes, through both parsers. (A *lone low* surrogate is fine on
both — the rule is narrower than "surrogate escapes".) The sweep is also **symmetric**: the other
direction — documents Ruby accepts and CPython refuses — was swept too and is **empty**, so the
list above is the whole difference between the two parsers and not just the half we went looking
for. That matters, because a member of the reverse set would show up as the mirror of the first
shape below: the Ruby path reporting a schema violation where the backend reports a parse failure.

On such a payload the backend does not word the failure differently; it does not have the same
failure. It parses the payload and validates it, so you get a schema violation with `-> ` reason
lines where the Ruby path gives you one `— could not parse annotation:` line. The file, the line,
the counts and the exit code still agree.

And if that payload is otherwise **schema-valid** — reachable only through the surrogate case,
since a number and a container cannot fill a slot the schema declares as a string — the backend
finds nothing wrong and **exits 0 where the Ruby path exits 1**. This is the one input on which
the two backends disagree about whether your suite passes. It is enumerated and asserted from both
sides, in the same places as the rows above.

Both are ratified rather than fixed, and the reason is scope: `allow_nan: true` and
`max_nesting: false` would close two of the three, but the surrogate case has no such option and
would mean porting CPython's string decoder into this gem — and all three would change what the
**default** Ruby path does, which the slice that added this backend deliberately holds fixed. See
`Scanner#parse` for the full reasoning; whether the gem should adopt CPython's acceptance grammar
is left open there rather than settled.

**If you go and count them.** The parity harness numbers this same enumeration two ways, and both
numbers are correct, so it is worth saying which is which before you follow the link. It *asserts*
them as six entries, `(i)`–`(vi)`, under "8b. the six enumerated backend differences" — the rows of
the table above, plus the two shapes the acceptance set takes. It *groups* them in its header as
four mechanisms, `(a)`–`(d)`, because the two unreadable-path rows share one cause and the two
acceptance-set shapes share another. Six entries, four mechanisms, one enumeration.

Those two totals live in that harness, which asserts them. This page does not restate them beside
the table, because a count kept in two places is a count that will eventually disagree with itself
— which is exactly how an earlier revision of this section came to announce three messages directly
above four rows.

Every way the backend can fail — the binary is missing, will not execute, exits with something that
is not a verdict, or emits output that is not a report — is **exit 2**, the linter's "could not do
my job" code. It never becomes exit 1, which means "an annotation is malformed" and nothing else.

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
literally, in both directions: if you chose a formatter that reports the run to a human
(`progress`, `documentation`, `--format failures`, `--format json`, …), it is left alone and
SpecGuard adds nothing to your output; if you chose none, you get RSpec's default (`progress`)
exactly as you would without this gem — same dots, same failures, same summary, byte for byte.

The qualifier on that first half is deliberate. SpecGuard restores the default when no *other*
registered formatter would give a human an account of the run, and it judges that by the formatter
protocol — whether anything answers to `example_started`, `example_passed`, `example_failed`,
`example_pending` or `dump_summary`. So if the only other formatter you registered is a silent one
(another telemetry gem, a custom notifier that writes elsewhere), SpecGuard reads the run as
unserved and restores `progress`, and you get output you did not have before. That is the error
direction chosen on purpose — noisy beats silent, which is the whole point of this behaviour — but
if you want a genuinely quiet run, name a formatter that reports the run and says little:
`--format failures` prints one line per failure and nothing else, so a green suite stays at zero
bytes and the restore does not fire.

That second half is not free, because RSpec installs its default formatter only when *no* formatter
was registered at all — so a gem that registers one silently suppresses it, and a failing suite
prints nothing. SpecGuard restores it on the first notification of the run, once RSpec has finished
deciding. If you want something other than `progress`, name it the usual way (`--format
documentation`, or `config.default_formatter = "doc"`) and that is what you will get, on its own.

"Byte for byte" is checked rather than asserted: `spec/specguard/rspec/formatter_run_spec.rb` runs
each wiring and the same suite with no SpecGuard at all, and diffs the two streams end to end with
only the two wall-clock numbers erased. Both a failing suite and a suite that reports through
`reporter.message` — an error in an `after(:context)` hook — are compared that way, because they
travel through different formatters and an addition that is invisible in one shows up in the other.

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

**A dry run is refused, to both sinks.** `rspec --dry-run` builds and reports
every example without executing a single body, so its per-example `duration` is
the cost of *constructing* an example (single-digit microseconds — a
`sleep 0.05` example understates its own runtime by three to four orders of
magnitude) and its `outcome` is `passed` for code that never
ran. Nothing downstream can tell the difference, and an all-green, near-instant
run is exactly the shape that poisons both the numbers SpecGuard reports. So
when RSpec is in dry-run mode the formatter makes no POST **and** writes no line
to `log/test_results.jsonl` — a file full of zero-duration green runs is the
same corruption, deferred until something replays it — and says so once:

```
SpecGuard: skipped test telemetry for a dry run (rspec --dry-run executes no
example bodies, so this run's durations and outcomes would not be
measurements). Nothing was sent or written; the test run is unaffected.
```

This matters most where you are least likely to look for it: an API key is
usually an environment-level secret rather than a job-level one, so a lint job
that runs `rspec --dry-run` to catch an unparseable spec file inherits the key
and would otherwise overwrite your suite's real duration and pass/fail picture
with zeroes and green.

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

---

<p align="center">
  <a href="https://yatfa.com">
    <img src="assets/built-with-yatfa.png" alt="Built with yatfa — a team of AI agents that plans, builds &amp; ships software." width="100%">
  </a>
</p>
