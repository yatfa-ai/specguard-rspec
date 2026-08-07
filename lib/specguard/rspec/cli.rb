# frozen_string_literal: true

require "optparse"

module SpecGuard
  module RSpec
    # `specguard-lint`'s command line, and the whole of the exit contract.
    #
    # == The contract, and the reason it needs defending
    #
    #   0  every annotation checked is valid (including "there were none")
    #   1  at least one annotation is malformed
    #   2  the linter could not do its job — misuse, or the tool itself broken
    #
    # Ruby does not give you this for free; it actively works against it.
    # `ruby -e 'raise "boom"'` exits **1**, and so does an uncaught
    # `OptionParser::InvalidOption`. So on the obvious implementation, every
    # internal failure lands on the one code the contract has already spent on
    # "an annotation is malformed":
    #
    #   * `specguard-lint --chnaged` — a typo — would exit 1, and CI would
    #     report a malformed annotation that does not exist;
    #   * a vendored schema missing from the packaged gem would exit 1, the
    #     same false accusation, in the field, on someone else's machine.
    #
    # The project has shipped this defect shape repeatedly — SPGD-35, SPGD-52,
    # SPGD-56 — but always as **false green**: a gate reporting success having
    # checked nothing. This is its inverse, **false red**: a tool failure
    # wearing the costume of a content failure. Both are the same underlying
    # bug, a gate whose failure states are indistinguishable, and for a linter
    # the exit code *is* the product.
    #
    # {#run} therefore rescues in three bands and returns rather than exits:
    # {UsageError} and {SchemaError} are named, and everything else that is not
    # a deliberate interruption is caught by a backstop. Exit 1 is produced in
    # exactly one place — a failed {Linter::Result} — so it means that and
    # nothing else.
    #
    # `Interrupt`, `SignalException` and `SystemExit` are deliberately *not*
    # caught. Ctrl-C must stay Ctrl-C; mapping it to "the linter is broken"
    # would be its own small lie.
    #
    # == All failures, not the first
    #
    # SPGD-12 §1 step 4 says the linter "exits 1 on the *first* malformed
    # annotation". Its own exit-code table, one paragraph later, says "1 | One
    # or more annotations are malformed", and the reference tool reports every
    # one: `bin/validate-intent --source broken_intent_spec.rb` emits 5 FAIL
    # blocks. Stopping at the first would turn one file into five CI
    # round-trips. Reporting all of them is the ratified behaviour (human
    # decision recorded on SPGD-82); the "first" wording is a known spec defect
    # with a correction filed against SPGD-12 §1 and the SPGD-73 roadmap text.
    #
    # == Two validators, one report
    #
    # {#run} has exactly one branch on which validator produced the verdicts —
    # the in-gem {Linter}, or the Go port shelled out to by {ValidatorBackend}
    # when `SPECGUARD_VALIDATE_INTENT` names a binary. Both arms return
    # {Linter::Result}s, so the branch closes immediately and the reporting and
    # exit-code logic below is shared rather than duplicated. With the variable
    # unset — the default, and the only configuration any existing user has —
    # nothing about this file's behaviour changes.
    #
    # The backend's failure modes are exit 2 by construction: {ValidatorError}
    # is rescued beside {UsageError}, which is what makes "the binary you named
    # is missing" read as `specguard-lint: error: …` rather than reaching the
    # backstop and reading as an `internal error:`. Either way it is a 2, and
    # that is the property that matters — a broken tool must not borrow the
    # code that means "your annotations are malformed".
    class CLI
      BANNER = "Usage: specguard-lint [options] [files...]"

      # Every annotation checked was valid — or there were none to check.
      # "Lint, don't require": a missing annotation is never an error.
      EXIT_OK = 0
      # One or more annotations are malformed. The only code produced by
      # inspecting content, and the only path that reaches it is a failed
      # {Linter::Result}.
      EXIT_MALFORMED = 1
      # The linter could not do its job: bad flags, `--changed` outside a git
      # repository, an unloadable schema, or an unexpected internal error.
      EXIT_MISUSE = 2

      def initialize(stdout: $stdout, stderr: $stderr, env: ENV)
        @stdout = stdout
        @stderr = stderr
        @env = env
      end

      # @param argv [Array<String>]
      # @return [Integer] 0, 1 or 2 — never anything else, and never by
      #   letting an exception reach the shell
      def run(argv)
        options = parse_options(argv)
        return EXIT_OK if options.nil? # --help / --version already printed

        # nil unless SPECGUARD_VALIDATE_INTENT names a usable binary, in which
        # case this raises rather than returning one that is not. Resolved
        # before anything is selected or scanned, for the same reason the
        # schema is: "the validator you asked for is not there" must never
        # surface as a run that checked nothing and called itself clean.
        backend = ValidatorBackend.resolve(env: @env)

        # Only on the Ruby path. When the backend is active the binary carries
        # its own schema and this gem's vendored copy governs nothing, so
        # loading it would let an unrelated packaging accident fail a run that
        # never reads it. The guard the load provides is not lost — the port
        # exits 2 on a schema it cannot load, and #run maps that to a
        # ValidatorError.
        schema = Schema.load if backend.nil?

        selection = select(options)
        report_selection(selection)

        results = check(selection.files, backend: backend, schema: schema)
        report_results(results)

        results.any?(&:failed?) ? EXIT_MALFORMED : EXIT_OK
      rescue UsageError, ValidatorError => e
        @stderr.puts "specguard-lint: error: #{e.message}"
        EXIT_MISUSE
      rescue SchemaError => e
        # Wording and stream follow bin/validate-intent:861-862 exactly.
        @stderr.puts "error: #{e.message}"
        EXIT_MISUSE
      rescue ScriptError, StandardError => e
        # The backstop that makes exit 1 mean one thing. Anything reaching here
        # is a bug in the linter, not a verdict about anyone's annotations, so
        # it is a 2 and it says so in those words.
        @stderr.puts "specguard-lint: internal error: #{e.class}: #{e.message}"
        EXIT_MISUSE
      end

      private

      # The one branch. Both arms produce the same {Linter::Result} list, so
      # everything downstream — the FAIL blocks, the summary line, the exit
      # code — is literally the same code rather than two renderers that have
      # to be kept in step.
      def check(files, backend:, schema:)
        return backend.check(files) if backend

        Linter.new(schema).check(Scanner.scan_files(files))
      end

      # Naming files and asking for the diff are contradictory instructions,
      # and honouring the first while dropping the second silently is the same
      # class of quiet no-op this tool exists to remove: `--changed` would
      # appear to have been applied. That is misuse — exit 2.
      def select(options)
        if options[:files].any?
          if options[:changed]
            raise UsageError,
                  "--changed cannot be combined with explicit files; drop one " \
                  "(named files are checked as given, --changed derives them from the diff)"
          end

          return FileSelector::Selection.new(files: options[:files], mode: :explicit)
        end

        FileSelector.select(changed: options[:changed], base: options[:base], root: options[:root])
      end

      # The honest-reporting half of the `--changed` fix: the selected-file
      # count is always stated, and an empty selection is loud on stderr, so
      # "checked 12 files, found nothing" can never be mistaken for
      # "checked nothing". The exit code is not the lever here — the contract
      # fixes 0 for "no annotations" — which is exactly why the warning has to
      # carry the weight.
      def report_selection(selection)
        if selection.empty?
          @stderr.puts "specguard-lint: warning: selected 0 spec files — #{empty_reason(selection)}"
          @stderr.puts "specguard-lint: warning: #{selection.note}" if selection.note
        else
          @stdout.puts "specguard-lint: checked #{selection.count} spec file#{'s' unless selection.count == 1}" \
                       "#{" changed since #{selection.base}" if selection.mode == :changed}"
        end
      end

      # `:explicit` is absent by construction — an explicit Selection is only
      # built from a non-empty file list, so it can never be empty.
      def empty_reason(selection)
        case selection.mode
        when :changed then changed_empty_reason(selection)
        else "no *_spec.rb found under #{Dir.pwd}"
        end
      end

      # Names the filter that actually emptied the selection. Saying "nothing in
      # the diff matched *_spec.rb" when a spec file demonstrably changed —
      # just not under this directory — is worse than saying nothing: it reads
      # as a conclusion and stops the reader looking.
      def changed_empty_reason(selection)
        stats = selection.stats
        base = selection.base

        return "nothing in the diff against #{base} matched *_spec.rb" if stats.nil?

        if stats.changed.zero?
          "nothing changed against #{base}"
        elsif stats.spec_matches.zero?
          "#{stats.changed} file#{'s' unless stats.changed == 1} changed against #{base}, " \
            "none matching *_spec.rb"
        elsif stats.outside_root.positive?
          "#{stats.spec_matches} changed spec file#{'s' unless stats.spec_matches == 1} against #{base}, " \
            "but #{stats.outside_root} #{stats.outside_root == 1 ? 'is' : 'are'} outside #{Dir.pwd} " \
            "(--changed selects only files under the current directory)"
        else
          "#{stats.spec_matches} changed spec file#{'s' unless stats.spec_matches == 1} against #{base} " \
            "could not be read"
        end
      end

      # The FAIL block, in the shape `bin/validate-intent --source` emits: two
      # spaces after `FAIL`, an em-dash before an extraction problem, eight
      # spaces and `-> ` before each schema reason.
      #
      #   FAIL  spec/order_spec.rb:9
      #           -> <root>: missing required property 'entity'
      #   FAIL  spec/order_spec.rb:28 — unterminated object literal (...)
      #
      # Two deliberate differences from the reference's `--source` mode, which
      # is a fixture self-test rather than a linter:
      #
      #   * no `PASS` line per valid annotation — a CI linter that prints a
      #     line per healthy annotation buries the failures in a large repo.
      #     The summary line carries the count instead, so "checked nothing"
      #     is still impossible to mistake for "all clean".
      #   * findings go to **stdout**, where the reference puts them and where
      #     lint findings conventionally go. Diagnostics about the linter
      #     itself (warnings, misuse, schema failure) stay on stderr, and the
      #     exit code — not the stream — is the machine-readable signal.
      def report_results(results)
        failures = results.reject(&:ok?)

        failures.each { |result| report_failure(result) }

        @stdout.puts summary_line(*results.partition { |result| result.kind != Finding::KIND_READ })
      end

      # The summary line exists for one reason — so "checked nothing" can never
      # read as "all clean" — which makes overstating what was inspected its
      # own kind of lie. A file that could not be opened contributed no
      # annotation, so counting its Result as one would report "checked 12
      # @intent annotations, 12 malformed" having read none of them. Unread
      # files get their own clause: neither folded into the annotation count
      # nor dropped from the report.
      def summary_line(annotations, unread)
        line = "specguard-lint: checked #{annotations.length} @intent annotation" \
               "#{'s' unless annotations.length == 1}, #{annotations.count(&:failed?)} malformed"
        return line if unread.empty?

        "#{line}; #{unread.length} file#{'s' unless unread.length == 1} could not be read"
      end

      def report_failure(result)
        if result.problem
          @stdout.puts "FAIL  #{result.location} — #{result.problem}"
        else
          @stdout.puts "FAIL  #{result.location}"
          result.reasons.each { |reason| @stdout.puts "        -> #{reason}" }
        end
      end

      def parse_options(argv)
        options = { changed: false, base: nil, root: Dir.pwd, files: [] }

        parser = OptionParser.new do |o|
          o.banner = BANNER
          o.on("--changed[=BASE]",
               "Only spec files changed against BASE (default: the merge base with the default branch)") do |base|
            options[:changed] = true
            options[:base] = base
          end
          o.on("-v", "--version", "Print the version and exit") do
            @stdout.puts "specguard-rspec #{VERSION}"
            return nil
          end
          o.on("-h", "--help", "Print this help and exit") do
            @stdout.puts o
            return nil
          end
        end

        options[:files] = parser.parse(argv)
        options
      rescue OptionParser::ParseError => e
        # Uncaught, this is the single likeliest way a user sees a false
        # "malformed annotation": OptionParser raises, Ruby exits 1. Retyping
        # it is what makes `--chnaged` a 2.
        raise UsageError, e.message
      end
    end
  end
end
