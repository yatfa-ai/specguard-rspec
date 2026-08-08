# frozen_string_literal: true

require "digest"
require "json"
require "open3"

module SpecGuard
  module RSpec
    # The opt-in Go validator backend: `validate-intent --source --json`.
    #
    # == What this is, and what it deliberately is not
    #
    # SPGD-96's Definition of Done ends "…and the Ruby gem invoking it for
    # linting … with the Ruby hand-rolled validation logic removed". This file
    # is the first half of that sentence. The second half is **not** done here,
    # and the reason is distribution rather than confidence:
    # `bin/validate-intent-go` is a build artifact in open-test-intent
    # (`.gitignore`), `/dist/` is ignored there with the comment "this repo
    # does not publish them", and this gem's whole premise is that it has *no
    # cross-repo runtime dependency* ({SCHEMA_PATH}). There is no release to
    # depend on. A default-on shell-out would therefore turn every existing
    # user's working linter into `specguard-lint: error: … No such file`.
    #
    # So the backend is **opt-in and off by default**. With
    # `SPECGUARD_VALIDATE_INTENT` unset, {resolve} returns nil and {CLI} runs
    # exactly the code it ran before this file existed — not "a code path that
    # should be equivalent", the same objects.
    #
    # == Why a dedicated seam rather than {Configuration}
    #
    # The originating proposal put this on `Configuration`. That is the wrong
    # object twice over: `Configuration` is the *telemetry* config — its only
    # consumers are `Formatter` and `Transport`, and `CLI` does not reference
    # it at all — so threading the lint backend through it would make the
    # linter depend on the telemetry object solely to read one env var. It also
    # memoizes process-wide (`SpecGuard::RSpec.configuration`), with
    # `reset_configuration!` existing only for tests, which is a poor fit for
    # something a spec wants to vary per example. {CLI} takes an `env:` instead
    # and asks this module, so the seam is one hash away in a test and one
    # method here in production.
    #
    # == The mapping, and the one thing the JSON document does not carry
    #
    # `RunSourceJSON` (open-test-intent, `cmd/validate-intent/report.go`)
    # NORMALIZES the reference's `problem` and `errors` into a single `errors`
    # list, saying so in a comment: "`problem` and `errors` are the same thing
    # to a consumer… `kind` is what tells them apart". {Linter::Result} keeps
    # them apart, and {CLI#report_failure} renders them differently — an em
    # dash on one line for a `problem`, an indented `-> ` line per `reason`.
    #
    # So the split has to be *reconstructed from `kind`*, which is exactly what
    # the Go comment says `kind` is for:
    #
    #   schema                     -> reasons: errors
    #   extraction / parse / read  -> problem: errors.first
    #   no-match                   -> problem, and see below
    #
    # For the three `problem` kinds an `errors` list of any length other than 1
    # is a **contract change**, not something to paper over by joining the
    # strings: the renderer would silently emit one line where the tool meant
    # several. {Runner} raises, and the run exits 2.
    #
    # == `no-match`: the gem's arguments are PATHS, the binary's are GLOBS
    #
    # `bin/validate-intent` expands its arguments with Python's
    # `glob.glob(..., recursive=True)`; `specguard-lint`'s are paths, checked as
    # given (`CLI#select`, `Scanner.scan_file`). Handing a path straight through
    # would silently re-expand it: `spec/fixtures/bracket[1]_spec.rb` becomes a
    # character class, and a file containing `*` becomes a wildcard that may
    # match *other* files. Every path is therefore escaped with {escape_glob},
    # the port of Python's `glob.escape`, so each argument matches exactly the
    # file it names or nothing at all.
    #
    # "Or nothing at all" is Go's `no-match` kind, which the gem has no
    # `Finding::KIND_*` for. It is mapped to {Finding::KIND_READ}, because that
    # is what it *means* on the gem's side of the seam: a named path that could
    # not be opened. The classification, the dropped line number, the "N files
    # could not be read" clause of the summary and the exit code all follow the
    # Ruby path exactly. Two things about it are deliberate:
    #
    #   * the reported file is the ORIGINAL path, not the escaped pattern —
    #     `[[]1]` is an artifact of this file and printing it would misreport
    #     what the caller asked for;
    #   * the wording is the gem's own, not Go's `no file(s) match <pattern>`,
    #     which is a statement about a *pattern* — a concept `specguard-lint`
    #     does not have, and whose text would carry the escaped form.
    #
    # This is one of the ratified differences between the backends, all of
    # which are asserted in `spec/specguard/rspec/validator_backend_spec.rb`
    # and in open-test-intent's `tests/parity/run_ruby_parity.sh`. That harness
    # counts them two ways and both are right, so expect it: its header GROUPS
    # them as four mechanisms, (a)-(d), while the section that asserts them is
    # headed "8b. the six enumerated backend differences" and numbers them
    # (i)-(vi) — this one and the acceptance set each cover two cases. Follow
    # the cross-reference and you are reading the six.
    #
    # The other three mechanisms are below. Only the first two are about TEXT —
    # the backend passing the port's wording through where the Ruby path spells
    # it its own way. The third is not a wording difference at all, which is why
    # this list no longer calls the group "text differences" as an earlier
    # revision did:
    #
    #   * the read-failure tail — see {Scanner.scan_text}, which records why
    #     the gem emits a fixed string where CPython and the port emit a
    #     decoder diagnostic;
    #   * the parse-failure tail — see {Scanner#parse} (1). A payload that
    #     survives normalisation and still is not JSON is described by
    #     whichever JSON parser saw it, so the Ruby path carries Ruby's
    #     `JSON::ParserError#message` and the backend carries CPython's. This
    #     is the most commonly hit of the three: `parse` is one of the three
    #     things the linter exists to report.
    #   * THE ACCEPTANCE SET — see {Scanner#parse} (2), and note that this one
    #     is not a wording difference at all. The two JSON parsers do not
    #     accept the same language: CPython takes non-finite literals, lone
    #     high surrogates and unbounded nesting, and Ruby takes none of the
    #     three. For such a payload the backend does not merely word the
    #     failure differently, it does not have one — it parses the payload and
    #     validates it, so the finding arrives as KIND_SCHEMA against the Ruby
    #     path's KIND_PARSE, and where the payload is schema-VALID the backend
    #     reports nothing at all and the two exit codes disagree.
    #
    # That last case is the only known input on which the two backends return
    # different verdicts for the same file, and it is ratified rather than
    # closed for reasons {Scanner#parse} sets out. Nothing here can detect it:
    # a document reporting no findings is exactly what a clean run looks like,
    # so the mapping below is correct and the disagreement is upstream of it.
    #
    # == Everything that can go wrong here is exit 2
    #
    # A missing binary, a binary that will not execute, a non-zero exit this
    # cannot read a document out of, or unparseable output are all "the linter
    # could not do its job". They must never reach exit 1, which the contract
    # has already spent on "an annotation is malformed" ({CLI}). Hence
    # {ValidatorError}, rescued beside {UsageError} so the message reads
    # `specguard-lint: error: …` rather than the backstop's `internal error:`.
    #
    # == Naming what produced the verdicts — and why identity is NOT in that band
    #
    # The paragraph above is about failures to obtain a VERDICT. The binary's
    # identity is not one, and the distinction is the whole of {#identity}.
    #
    # This file already refuses to let "which validator ran" be ambiguous in the
    # two places it can be decided: a named-but-missing binary is a hard exit 2
    # ({Runner#verify!}), and a bare command name is refused rather than
    # PATH-resolved ({Runner#path_hint}) because "a run that succeeded against a
    # different validator … nothing downstream can detect". Both close the hole
    # for binaries that do not resolve. For every binary that DOES resolve, the
    # run was still silent about it: a report produced by the port and a report
    # produced by {Linter} were the same bytes.
    #
    # So {Runner#verify!} asks the binary who it is, once, before anything is
    # selected or scanned — the same fail-early placement as the checks beside
    # it — and {Runner#provenance} renders the answer for the one stderr line
    # {CLI} prints per run. Three properties make that safe:
    #
    #   * it is asked ONCE per run, so it cannot become a per-batch cost on a
    #     large audit. Not by memoizing the answer — {Runner#verify!} re-probes
    #     every time it is called, exactly as it re-runs the three file checks
    #     beside it — but because {ValidatorBackend.resolve} is the only thing
    #     that calls {Runner#verify!} and {CLI} resolves once per run;
    #   * the answer is passed through VERBATIM. A line the gem composed about
    #     the binary would be a claim by the gem; the point is to carry the
    #     binary's own statement, which is the only thing that can distinguish
    #     two builds this gem has never heard of;
    #   * a binary that cannot answer still validates. `--version` arrived in
    #     open-test-intent slice 6; an older build reads it as a filename,
    #     reports "no file(s) match" on stderr and exits 1. That must not cost
    #     a verdict, so the probe treats a non-zero exit, empty output, or
    #     output that cannot be rendered as one line as "identity unavailable"
    #     and never as a {ValidatorError}. `SystemCallError` is caught in the
    #     probe rather than left to {Runner#run}'s rescue for the same reason.
    #
    # "Unavailable" is then reported IN WORDS by {Runner#provenance}. Dropping
    # the line instead would make a run that could not name its validator look
    # exactly like a run nobody looked at — the silent-omission shape this
    # project keeps naming, arrived at from a third direction.
    #
    # == Asking the answer a question: the schema contract across the seam
    #
    # The identity above was carried through and rendered, and nothing read it.
    # One token in it is not decoration: open-test-intent's `VersionLine`
    # (`cmd/validate-intent/version.go`) ends `schema sha256:<64-hex>`, the
    # digest of the schema COMPILED INTO that binary, and `schema.go`'s
    # `SchemaSHA256` says in as many words why it exists —
    #
    #   "a gem that vendors schema A can be pointed at a binary built when
    #   canonical was B, and all three guards stay green while the two halves
    #   enforce different contracts."
    #
    # Every drift guard in this ecosystem compares a matched pair inside ONE
    # checkout: `schema_test.go` digests the Go embed against the Go tree's
    # `schemas/`, `spec/specguard/rspec/schema_packaging_spec.rb` digests this
    # gem's vendored copy against this gem's pin, `tests/parity/` compares two
    # files in two checkouts. None of them looks at an INSTALLED artifact, and
    # none of them can. The seam is ordinary, not contrived: `install.sh` fetches
    # a released binary by version with nothing tying that release's vintage to
    # the gem beside it, and {ENV_VAR} accepts any path on the host.
    #
    # And on this path the gem does not even read its own schema — `CLI#run`
    # loads it only when the backend is nil, deliberately, because with the
    # backend on the binary's copy is what governs. So the two contracts never
    # met. {Runner#verify!} is where they now do, beside the three file checks
    # and before anything is selected or scanned: the same fail-early placement
    # this file already argues for, and for the same reason — a divergence is
    # not a verdict about anyone's annotations.
    #
    # Three bands, and the boundaries between them are the whole design:
    #
    #   * REPORTED AND EQUAL — the run proceeds and {Runner#provenance} says the
    #     contract matched. The wording may NOT say the run *enforced* it, and
    #     that is not pedantry: `LoadSchema` (`cmd/validate-intent/fileio.go`)
    #     gives a `schemas/open-test-intent.v1.json` found beside the executable
    #     priority over the embedded copy, and `--version` returns above that
    #     decision and never reaches it. The digest is the contract the artifact
    #     CARRIES. Claiming more would be this gem inventing a guarantee out of
    #     an answer that does not contain one.
    #
    #   * REPORTED AND DIFFERENT — {ValidatorError}, exit 2, naming BOTH
    #     digests. This is the one addition to the exit-2 band, and it belongs
    #     there for the reason the band exists: a verdict produced under a
    #     different contract is not a verdict this gem can stand behind, and
    #     nothing downstream can notice — the report is a normal report, the
    #     exit code is a normal exit code, and the findings are whatever the
    #     other contract implies. Note this is the OPPOSITE of the identity
    #     rule above rather than an exception to it: "I could not ask" stays
    #     out of the band, "I asked and the answer was wrong" goes in.
    #
    #   * NOT REPORTED — never a refusal, in any of its three shapes: a
    #     pre-slice-17 build whose `--version` carries no digest token, a binary
    #     that could not answer `--version` at all, and this gem being unable to
    #     read its own vendored schema. Each says so IN WORDS in its own
    #     wording, because "could not check" and "checked and clean" are two
    #     different statements and a checker owes both.
    #
    # That third shape is the one judgment call here, so it is recorded rather
    # than left to be re-derived. {Schema.load}'s precedent is that an
    # unreadable {SCHEMA_PATH} is exit 2 — but that is a schema the run is about
    # to ENFORCE, and this one is not: `CLI#run` skips the load on this path
    # precisely so an unrelated packaging accident cannot fail a run that never
    # reads it, and making the digest fatal here would re-introduce exactly the
    # dependency that comment removed. An unreadable vendored copy is also not
    # what the exit-2 arm is for — divergence is a POSITIVE finding, two digests
    # that differ, and a missing operand is not a difference. So it lands in the
    # third band and is said out loud. (Hence {Digest::SHA256.file} rather than
    # {Schema.load}: this needs bytes, not a parsed and validated document, so
    # only an unreadable file can fail it and a schema this run does not use
    # cannot fail it twice.)
    #
    # The digest is computed from {SCHEMA_PATH} at runtime and never written
    # down here. A constant would be a fourth copy of a hex string that already
    # exists in three places, drifting independently of the file it claims to
    # describe — which is the precise failure this whole check was added to
    # detect, re-created inside the detector.
    module ValidatorBackend
      # Set it to a `validate-intent` binary to route linting through the Go
      # port. Blank or unset means the Ruby path, which is the default and the
      # only behaviour any existing user has.
      ENV_VAR = "SPECGUARD_VALIDATE_INTENT"

      # @param env [Hash, ENV]
      # @return [Runner, nil] nil when the backend is not requested
      # @raise [ValidatorError] when it is requested and unusable
      def self.resolve(env: ENV)
        # Blank means unset, following `Configuration`'s `blank_to_nil` idiom:
        # `SPECGUARD_VALIDATE_INTENT=` in a CI environment file is somebody
        # turning the backend *off*, not asking for a binary named "".
        path = env[ENV_VAR].to_s.strip
        return nil if path.empty?

        Runner.new(path).tap(&:verify!)
      end

      # Python's `glob.escape` for POSIX paths: wrap each of `*`, `?` and `[`
      # in a character class, which makes it match itself literally. `]` is not
      # escaped and does not need to be — outside a class it is already a
      # literal — and CPython does not escape it either.
      #
      # @param path [String]
      # @return [String] a glob pattern matching exactly `path`
      def self.escape_glob(path)
        path.gsub(/([*?\[])/, '[\1]')
      end

      # Invokes the binary and turns its report into {Linter::Result}s.
      class Runner
        # `kind` -> the gem's equivalent. `no-match` has no equivalent of its
        # own and folds into KIND_READ; see the module comment.
        KINDS = {
          "schema" => Finding::KIND_SCHEMA,
          "extraction" => Finding::KIND_EXTRACTION,
          "parse" => Finding::KIND_PARSE,
          "read" => Finding::KIND_READ,
          "no-match" => Finding::KIND_READ
        }.freeze

        # Kinds that are a statement about a FILE rather than about an
        # annotation site. They contribute nothing to `summary.annotations`,
        # exactly as `CLI#summary_line` keeps unread files out of the gem's own
        # annotation count.
        NON_ANNOTATION_KINDS = %w[read no-match].freeze

        # A full audit passes every spec file in the repository — thousands of
        # arguments on a large suite — and an argument vector has two separate
        # kernel limits on Linux: `ARG_MAX` caps the TOTAL vector (a quarter of
        # the stack rlimit, so typically ~2 MiB) and `MAX_ARG_STRLEN` caps each
        # SINGLE argument at 128 KiB. Exceeding either is `E2BIG`. This budget
        # is for the first, and is deliberately well under the typical value
        # rather than derived from it: the limit is not portable (it is smaller
        # on some kernels and much smaller on other Unixes), and there is
        # nothing to gain from crowding it. The batches are an implementation
        # detail: {#check} concatenates their findings in argument order, so the
        # caller still gets one list and {CLI} still prints one selection line
        # and one summary line.
        MAX_ARG_BYTES = 96 * 1024
        # A second, independent bound. Some kernels cap the argument *count*
        # (and `MAX_ARG_BYTES` alone would allow ~90k one-character paths).
        MAX_BATCH_FILES = 1_000

        # The `--version` probe's own guard rail, and the only thing it asserts
        # about the answer's SHAPE. The identity is passed through verbatim, so
        # the question is not "is this the format I expect" — a future build may
        # word it differently and still be telling the truth — but "can this be
        # rendered as the one line {CLI} promises per run". A binary answering
        # `--version` with a report document, a stack trace, or a megabyte of
        # anything is answering a different question, and its output would break
        # the line rather than fill it.
        IDENTITY_MAX_BYTES = 200

        # The one token of the identity line this file interprets, matched
        # exactly as `cmd/validate-intent/version.go` writes it: the literal
        # `schema sha256:` followed by 64 hex digits. Everything around it stays
        # opaque — the version, the toolchain, the platform and anything a
        # future build appends are still the binary's business.
        #
        # Anchored at both ends. Without the trailing boundary a 65-digit token
        # would match its first 64 and be compared as if it were a digest; with
        # it, such a token matches nothing and the run lands in the "not
        # reported" band, which is the right answer for a line this gem cannot
        # read rather than one it disagrees with.
        #
        # Case-insensitive, and the capture is compared downcased. Go's
        # `hex.EncodeToString` is lower case and {Digest::SHA256#hexdigest} is
        # too, so today this changes nothing; if a future build shouts, that is
        # a spelling of the same digest and must not be reported as divergence.
        SCHEMA_DIGEST_PATTERN = /\bschema sha256:(\h{64})\b/i

        attr_reader :path

        # The binary's own `--version` line, or nil when it could not report
        # one. Populated by {#verify!}; nil before it runs, which is why nothing
        # constructs a Runner without it (see {ValidatorBackend.resolve}).
        #
        # Assigned unconditionally rather than memoized: a second {#verify!}
        # re-probes, in step with the file checks it sits among, which also
        # re-run. "Once per run" is a property of the single {#verify!} call
        # {ValidatorBackend.resolve} makes, not of a cache here.
        #
        # @return [String, nil]
        attr_reader :identity

        # The result of the schema-contract comparison, one of:
        #
        #   :matched       — the binary reported a digest and it is ours
        #   :unreported    — it named itself but carries no digest token
        #   :unidentified  — it could not name itself at all
        #   :unreadable    — we could not read our own vendored schema
        #
        # There is no `:diverged` member: that band raises out of {#verify!}, so
        # no Runner ever exists holding it. Populated by {#verify!} beside
        # {#identity}, and nil before it runs for the same reason.
        #
        # @return [Symbol, nil]
        attr_reader :schema_contract

        # @param path [String] the `validate-intent` binary
        def initialize(path)
          @path = path
        end

        # Fails before anything is selected or scanned, so "the backend you
        # asked for is not there" is never mistaken for a verdict about
        # anyone's annotations.
        #
        # The identity probe rides along for the placement rather than for the
        # check: asking here is what makes it once-per-run and ahead of
        # selection. It cannot fail the run — see the module comment.
        #
        # The schema-contract comparison reads the answer the probe already
        # obtained, so it costs no second process, and it CAN fail the run —
        # see the module comment for why that one band belongs in exit 2 while
        # the identity itself does not.
        #
        # @raise [ValidatorError]
        def verify!
          raise ValidatorError, "#{describe} does not exist#{path_hint}" unless File.exist?(@path)
          raise ValidatorError, "#{describe} is not a file" unless File.file?(@path)
          raise ValidatorError, "#{describe} is not executable" unless File.executable?(@path)

          @identity = probe_identity
          @schema_contract = verify_schema_contract!
          self
        end

        # The active arm of {CLI}'s one-line-per-run provenance statement.
        #
        # The identity half is the binary's own words, uninterpreted. The path
        # is spelled exactly as every diagnostic in this file spells it, so the
        # line naming the validator and any error about it name the same thing.
        #
        # The clause after it is the gem's own, because it is a statement about
        # a COMPARISON the gem made and not about the binary. Each of the four
        # states it can report is worded distinctly: three of them mean the
        # contract was not checked, for three different reasons, and collapsing
        # them into one sentence would leave an operator unable to tell a build
        # too old to answer from an installation missing its own schema.
        #
        # @return [String]
        def provenance
          if @identity.nil?
            return "validated by the binary at #{@path} (#{ENV_VAR}), which could not report its identity, " \
                   "so the schema contract it carries could not be checked"
          end

          "validated by #{@identity} at #{@path} (#{ENV_VAR})#{schema_contract_clause}"
        end

        # @param paths [Enumerable<String>] spec files, as the caller named them
        # @return [Array<Linter::Result>] in argument order
        # @raise [ValidatorError] on any failure to obtain a report
        def check(paths)
          paths = paths.to_a
          # `validate-intent --source` with no argument is a usage error (exit
          # 2) — and there is nothing to ask it. `CLI#report_selection` has
          # already warned about the empty selection.
          return [] if paths.empty?

          batch(paths).flat_map { |group| check_batch(group) }
        end

        private

        def describe
          "the validator backend at #{@path} (#{ENV_VAR})"
        end

        # A bare command name is refused rather than resolved against PATH, and
        # the refusal says how to fix it. Which binary a CI job validated
        # against should not depend on what else happens to be installed and in
        # what order — and the failure that arrangement produces is a run that
        # succeeded against a different validator, which nothing downstream can
        # detect. One shell substitution buys a value that means one thing.
        def path_hint
          return "" if @path.include?(File::SEPARATOR)

          " — #{ENV_VAR} takes a path, not a command name; try #{ENV_VAR}=\"$(command -v #{@path})\""
        end

        # Asks the binary who it is. Never raises: every way this can go wrong
        # is "identity unavailable", which {#provenance} reports in words.
        #
        # `--version` is position-independent in the port and answers on stdout
        # with exit 0 (`cmd/validate-intent/main.go`), so the whole answer is
        # `stdout` and the exit code is a usable gate. A pre-slice-6 build has
        # no such flag: it reads `--version` as a filename, writes "no file(s)
        # match" to STDERR and exits 1 — caught by the exit check, with the
        # stdout checks behind it in case some other build answers differently.
        #
        # The `SystemCallError` rescue is local rather than shared with {#run}'s
        # because the two mean opposite things: there, a binary that will not
        # execute is a run with no verdict and an exit 2; here it is a question
        # that went unanswered, and {#check} will reach the same failure a
        # moment later with the diagnostic that belongs to it.
        #
        # @return [String, nil]
        def probe_identity
          stdout, _stderr, status = Open3.capture3(@path, "--version")
          return nil unless status.success?

          identity_line(stdout)
        rescue SystemCallError
          nil
        end

        # The one shape check, and it is about renderability rather than
        # format — see {IDENTITY_MAX_BYTES}. Anything that survives is returned
        # byte for byte apart from surrounding whitespace, which is the
        # newline `--version` ends with.
        #
        # The encoding test comes FIRST because `String#strip` raises
        # `Encoding::CompatibilityError` on an invalid byte sequence, and an
        # exception here would reach {CLI}'s backstop and turn a binary with an
        # odd `--version` into `internal error:` and an exit 2 — the exact cost
        # this probe is not allowed to have.
        #
        # @return [String, nil]
        def identity_line(stdout)
          return nil unless stdout.to_s.valid_encoding?

          text = stdout.to_s.strip
          return nil if text.empty? || text.bytesize > IDENTITY_MAX_BYTES
          # A control character — a second line, an ANSI escape, a NUL — would
          # break the single line this becomes, or forge extra ones.
          return nil if text.match?(/[[:cntrl:]]/)

          text
        end

        # The comparison itself. Returns the state {#schema_contract} reports,
        # and raises for the one band that is a refusal.
        #
        # It reads {#identity}, which {#verify!} has just assigned — not a
        # second `--version` — so the digest and the name in the provenance
        # line are guaranteed to have come from the same process. Two probes
        # could not promise that, and a run whose line named one build while
        # the comparison used another would be worse than no comparison.
        #
        # @return [Symbol]
        # @raise [ValidatorError] when both digests are known and differ
        def verify_schema_contract!
          return :unidentified if @identity.nil?

          reported = @identity[SCHEMA_DIGEST_PATTERN, 1]&.downcase
          return :unreported if reported.nil?

          vendored = vendored_schema_digest
          return :unreadable if vendored.nil?
          return :matched if reported == vendored

          # Both digests, spelled in full. A message naming only one of them
          # would send the reader to compute the other by hand, and the whole
          # point of this diagnostic is that the two halves are in different
          # places — one inside a binary, one inside an installed gem — and
          # neither is inspectable from where the other lives.
          #
          # The identity is named too, because the question that comes straight
          # after "these differ" is "WHICH build is this, so I know which half
          # to move" — and the path alone does not answer it: the same path can
          # hold a different binary tomorrow. The probe already holds the
          # version string, and this refusal happens above {#provenance}, so
          # unless the error says it nothing in the run ever does.
          raise ValidatorError,
                "#{describe} reports carrying schema sha256:#{reported}, but this gem vendors " \
                "sha256:#{vendored} — the two halves would enforce different contracts, so this run " \
                "would produce a verdict this gem cannot stand behind; the binary identifies itself " \
                "as #{@identity}"
        end

        # This gem's own contract, digested from the file at runtime. Never a
        # constant: see the module comment.
        #
        # nil rather than an exception on an unreadable file, which puts a
        # broken installation in the "could not check" band instead of failing
        # a run that does not otherwise read this file at all. `Errno::ENOENT`
        # and `Errno::EACCES` are `SystemCallError`s; `IOError` covers the rest
        # of the ways a read can end without one.
        #
        # @return [String, nil] 64 lower-case hex digits
        def vendored_schema_digest
          Digest::SHA256.file(SCHEMA_PATH).hexdigest
        rescue SystemCallError, IOError
          nil
        end

        # The tail of the provenance line, one sentence per state. The matched
        # arm is careful twice over: "reports carrying" attributes the claim to
        # the binary, and the clause after the dash refuses the stronger reading
        # the reader would otherwise supply for free — see the module comment on
        # `LoadSchema`, which `--version` never reaches.
        def schema_contract_clause
          case @schema_contract
          when :matched
            ", which reports carrying the schema this gem vendors — the contract it carries, " \
              "not necessarily the one this run enforced"
          when :unreadable
            ", whose schema contract could not be checked: this gem could not read its own vendored copy"
          else
            ", which reports no schema digest, so the contract it carries could not be checked"
          end
        end

        # Greedy, order-preserving, and never empty: a single path longer than
        # the byte budget still gets its own batch rather than being silently
        # dropped from the run.
        #
        # That is a weaker promise than "it still gets checked", and
        # deliberately so. A path over `MAX_ARG_STRLEN` (128 KiB) is refused by
        # `execve` however it is batched — no grouping can make one argument
        # smaller — so it lands in {#run}'s `SystemCallError` rescue and the run
        # is exit 2. What batching buys is that the failure is LOUD: the file is
        # never quietly omitted from a report that then calls itself clean,
        # which is the silent-omission shape this project keeps naming.
        def batch(paths)
          groups = [[]]
          bytes = 0

          paths.each do |path|
            size = ValidatorBackend.escape_glob(path).bytesize + 1
            if !groups.last.empty? && (bytes + size > MAX_ARG_BYTES || groups.last.length >= MAX_BATCH_FILES)
              groups << []
              bytes = 0
            end
            groups.last << path
            bytes += size
          end

          groups
        end

        def check_batch(paths)
          # The pattern list keeps DUPLICATES. `specguard-lint a a` reports
          # every annotation twice — the Ruby path checks the files it is
          # handed, in the order it is handed them, without de-duplicating —
          # and so does the port. Deriving the argument vector from the
          # lookup hash below instead would silently collapse them and halve
          # the report.
          patterns = paths.map { |path| ValidatorBackend.escape_glob(path) }
          # escaped pattern -> the path the caller named. Used to undo
          # {escape_glob} on a `no-match`, whose `file` is the pattern rather
          # than a path that exists. Collapsing duplicates here is harmless:
          # the same pattern always maps back to the same path.
          originals = patterns.zip(paths).to_h

          document = run(patterns)
          findings = fetch_findings(document)
          check_annotation_count(document, findings)

          findings.map { |finding| result_for(finding, originals) }
        end

        # @return [Hash] the parsed report document
        def run(patterns)
          # No shell: the argument vector goes straight to execve, so a path
          # containing a space or a quote needs no quoting and cannot be
          # re-split. (`--json` is position-independent in the port; it is
          # written next to `--source` for readability.)
          stdout, stderr, status = Open3.capture3(@path, "--source", "--json", *patterns)

          check_status(status, stderr)
          parse_document(stdout, stderr)
        rescue SystemCallError => e
          # ENOENT/EACCES between #verify! and here (a binary deleted or
          # chmod'ed mid-run), ENOEXEC for a file that is not a program, E2BIG
          # if the batching above is ever outgrown.
          raise ValidatorError, "#{describe} could not be executed: #{e.message}"
        end

        # The port's own contract: 0 when everything checked was valid, 1 when
        # something was not. Anything else — 2 for a schema it could not load
        # or a mode it refuses, or death by signal — means it produced no
        # verdict, and neither may this run.
        def check_status(status, stderr)
          return if [0, 1].include?(status.exitstatus)

          raise ValidatorError, "#{describe} #{exit_description(status)}#{trailing(stderr)}"
        end

        def exit_description(status)
          return "exited #{status.exitstatus}" if status.exitstatus

          "did not exit normally (#{status})"
        end

        def parse_document(stdout, stderr)
          document = JSON.parse(stdout)
          unless document.is_a?(Hash)
            raise ValidatorError, "#{describe} emitted a #{document.class} where a JSON object was expected"
          end

          # `--source` is the only mode this asks for and the only one the port
          # implements `--json` for. A document announcing anything else means
          # the argument vector above no longer says what this code thinks it
          # says.
          mode = document["mode"]
          raise ValidatorError, "#{describe} reported mode #{mode.inspect}, expected \"source\"" unless mode == "source"

          document
        rescue JSON::ParserError => e
          raise ValidatorError,
                "#{describe} did not emit a JSON document: #{e.message}#{trailing(stderr)}"
        end

        def fetch_findings(document)
          findings = document["findings"]
          raise ValidatorError, "#{describe} emitted no `findings` array" unless findings.is_a?(Array)
          unless findings.all?(Hash)
            raise ValidatorError, "#{describe} emitted a `findings` entry that is not a JSON object"
          end

          findings
        end

        # The port counts ANNOTATION SITES EXAMINED in `summary.annotations`,
        # and a read failure or a no-match contributes none. So the count and
        # the findings are two independent statements about the same run, and
        # comparing them is what catches output truncated by a full pipe or a
        # killed batch — a case that would otherwise show up as a *smaller*
        # clean report, which is precisely the shape nobody notices.
        def check_annotation_count(document, findings)
          declared = document.dig("summary", "annotations")
          unless declared.is_a?(Integer)
            raise ValidatorError, "#{describe} emitted no integer `summary.annotations`"
          end

          seen = findings.count { |finding| !NON_ANNOTATION_KINDS.include?(finding["kind"]) }
          return if seen == declared

          raise ValidatorError,
                "#{describe} reported #{declared} annotation(s) but emitted #{seen} annotation finding(s)"
        end

        def result_for(finding, originals)
          file = finding["file"]
          raise ValidatorError, "#{describe} emitted a finding with no `file`" unless file.is_a?(String)

          kind = finding["kind"]
          errors = finding_errors(finding, file)

          return passing_result(finding, file, kind, errors) if finding["ok"] == true

          failing_result(finding, file, kind, errors, originals)
        end

        def finding_errors(finding, file)
          errors = finding["errors"]
          unless errors.is_a?(Array) && errors.all?(String)
            raise ValidatorError, "#{describe} emitted a finding on #{file} whose `errors` is not a list of strings"
          end

          errors
        end

        def passing_result(finding, file, kind, errors)
          unless kind.nil? && errors.empty?
            raise ValidatorError,
                  "#{describe} emitted a passing finding on #{file} carrying kind #{kind.inspect} " \
                  "and #{errors.length} error(s)"
          end

          Linter::Result.new(file: file, line: line_of(finding, file))
        end

        def failing_result(finding, file, kind, errors, originals)
          mapped = KINDS[kind]
          # An unknown kind is a vocabulary the port grew and this file has not
          # been taught. Guessing would render it under whichever branch of
          # #report_failure it fell into by accident; refusing keeps the
          # divergence visible and costs one exit 2.
          raise ValidatorError, "#{describe} emitted the unknown kind #{kind.inspect} on #{file}" if mapped.nil?
          raise ValidatorError, "#{describe} emitted a failing finding on #{file} with no errors" if errors.empty?

          return schema_result(finding, file, errors) if kind == "schema"

          problem_result(finding, file, kind, errors, originals)
        end

        def schema_result(finding, file, errors)
          Linter::Result.new(file: file, line: line_of(finding, file),
                             kind: Finding::KIND_SCHEMA, reasons: errors)
        end

        def problem_result(finding, file, kind, errors, originals)
          unless errors.length == 1
            # See the module comment: joining these would collapse several
            # lines the tool meant to print into one em-dashed sentence.
            raise ValidatorError,
                  "#{describe} emitted #{errors.length} errors on a #{kind} finding for #{file}, " \
                  "where the report can render exactly one"
          end

          return no_match_result(file, originals) if kind == "no-match"

          Linter::Result.new(file: file, line: line_of(finding, file),
                             kind: KINDS.fetch(kind), problem: errors.first)
        end

        # A path that matched nothing. Reported against the path the caller
        # named — `originals` undoes {ValidatorBackend.escape_glob} — and in
        # the gem's own words, because Go's "no file(s) match <pattern>" is a
        # statement about a glob pattern this CLI does not have and would carry
        # the escaped spelling into the report.
        def no_match_result(pattern, originals)
          Linter::Result.new(file: originals.fetch(pattern, pattern), line: 0,
                             kind: Finding::KIND_READ,
                             problem: "could not read file: no file at this path")
        end

        # `line` is null exactly where the finding is not line-scoped, which is
        # the same rule `Linter::Result#location` applies from the other side —
        # it drops the line for KIND_READ. 0 is the sentinel `Scanner` already
        # uses for a finding that never reached a line.
        def line_of(finding, file)
          line = finding["line"]
          return 0 if line.nil?
          raise ValidatorError, "#{describe} emitted a non-integer `line` on #{file}" unless line.is_a?(Integer)

          line
        end

        # The binary's stderr, appended to a diagnostic when it said anything.
        # A `--json` run that failed to produce a document has usually
        # explained itself there ("error: could not load schema …"), and
        # dropping it would leave the operator with "it did not emit a JSON
        # document" and nothing to act on.
        def trailing(stderr)
          text = stderr.to_s.strip
          return "" if text.empty?

          " — it said: #{text.lines.first.strip}"
        end
      end
    end
  end
end
