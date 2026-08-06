# frozen_string_literal: true

require "optparse"

module SpecGuard
  module RSpec
    # `specguard-lint`'s command line.
    #
    # == This slice always exits 0
    #
    # The `0`/`1`/`2` exit contract (SPGD-12 §1) is the *next* slice. Until the
    # schema is actually applied, a non-zero exit would be a lie: nothing here
    # can tell a valid annotation from an invalid one, so there is no failure to
    # report. {#run} therefore returns 0 unconditionally, including for the
    # {UsageError} that will later map to 2 — the error is raised, typed, and
    # reported on stderr today, and only its *exit code* is deferred.
    class CLI
      BANNER = "Usage: specguard-lint [options] [files...]"

      def initialize(stdout: $stdout, stderr: $stderr)
        @stdout = stdout
        @stderr = stderr
      end

      # @param argv [Array<String>]
      # @return [Integer] always 0 in this slice — see the class comment.
      def run(argv)
        options = parse_options(argv)
        return 0 if options.nil? # --help / --version already printed

        selection = select(options)
        report_selection(selection)

        # `selection.files` are relative to the selection root, which for the
        # CLI is always the process's own working directory — so they are used
        # as-is. Explicitly-named files pass straight through, absolute or not.
        findings = Scanner.scan_files(selection.files)
        report_findings(findings)

        0
      rescue UsageError => e
        # Will be exit 2 once the exit contract lands. Loud now regardless.
        @stderr.puts "specguard-lint: #{e.message}"
        0
      end

      private

      def select(options)
        return FileSelector::Selection.new(files: options[:files], mode: :explicit) if options[:files].any?

        FileSelector.select(changed: options[:changed], base: options[:base], root: options[:root])
      end

      # The honest-reporting half of the `--changed` fix: the selected-file
      # count is always stated, and an empty selection is loud on stderr, so
      # "checked 12 files, found nothing" can never be mistaken for
      # "checked nothing".
      def report_selection(selection)
        if selection.empty?
          @stderr.puts "specguard-lint: warning: selected 0 spec files — #{empty_reason(selection)}"
          @stderr.puts "specguard-lint: warning: #{selection.note}" if selection.note
        else
          @stdout.puts "specguard-lint: checked #{selection.count} spec file#{'s' unless selection.count == 1}" \
                       "#{" changed since #{selection.base}" if selection.mode == :changed}"
        end
      end

      def empty_reason(selection)
        case selection.mode
        when :changed then "nothing in the diff against #{selection.base} matched *_spec.rb"
        when :explicit then "no files were given"
        else "no *_spec.rb found under #{Dir.pwd}"
        end
      end

      def report_findings(findings)
        extracted, problems = findings.partition(&:extracted?)

        problems.each do |finding|
          @stderr.puts "#{finding.location}: #{finding.problem}"
        end

        extracted.each do |finding|
          @stdout.puts "#{finding.location}: #{JSON.generate(finding.intent)}"
        end

        @stdout.puts "specguard-lint: found #{findings.length} @intent annotation" \
                     "#{'s' unless findings.length == 1} " \
                     "(#{extracted.length} extracted, #{problems.length} malformed)"
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
        raise UsageError, e.message
      end
    end
  end
end
