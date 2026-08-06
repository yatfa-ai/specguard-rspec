# frozen_string_literal: true

module SpecGuard
  module RSpec
    # Chooses which spec files the linter reads.
    #
    # Two modes: every `*_spec.rb` under the working directory (the default), or
    # only those in the current diff (`--changed`).
    #
    # == Why `--changed` is not `git diff --name-only`
    #
    # The Client Gem spec words `--changed` as "files in the current diff (via
    # `git diff --name-only`)". Taken literally that is **broken in CI**: bare
    # `git diff --name-only` compares the *working tree against the index*, and
    # CI checks out a commit and leaves the tree clean. It therefore matches
    # nothing, the linter selects zero files, finds zero annotations, and exits
    # 0 — the CI gate the tool exists to provide, silently a no-op.
    #
    # So the diff base is an explicit decision, made here and documented here
    # rather than inherited by accident:
    #
    #   * `--changed` diffs against the **merge base with the default branch**
    #     (`origin/HEAD`, falling back to `origin/main`/`origin/master` and then
    #     their local counterparts). On a feature branch that is exactly "what
    #     this branch changed", whether or not the change is committed yet —
    #     `git diff <base>` with no second commit compares the base against the
    #     *working tree*, so it covers both.
    #   * `--changed=<base>` overrides it, for a CI system that knows better
    #     (a PR's target ref, say).
    #
    # **This still legitimately selects zero files**, and that is not a bug to
    # be fixed by a cleverer base: on a default-branch build after a merge,
    # `HEAD == origin/main`, so the merge base *is* HEAD and nothing differs.
    # There is no diff base that makes "what changed on this build" non-empty
    # there.
    #
    # That is why the load-bearing requirement is the **loud empty selection**,
    # not the base. The caller must never be unable to tell "checked 12 files,
    # found no annotations" from "checked 0 files" — {Selection} carries the
    # count and the emptiness so the CLI can say so on stderr. The exit code is
    # not the lever: the spec fixes 0 for "no annotations".
    #
    # Known limitation: `git diff` cannot see **untracked** files, so a brand
    # new spec file that has not been `git add`ed is not selected. In CI (a
    # clean checkout of a commit) that cannot arise; locally the loud empty
    # selection is what surfaces it.
    module FileSelector
      DEFAULT_GLOB = "**/*_spec.rb"

      # Ordered probes for the default branch when no explicit base is given.
      DEFAULT_BRANCH_REFS = %w[origin/HEAD origin/main origin/master main master].freeze

      # What a selection produced, plus enough context to report it honestly.
      Selection = Data.define(:files, :mode, :base, :note) do
        def initialize(files:, mode:, base: nil, note: nil)
          super
        end

        def empty?
          files.empty?
        end

        def count
          files.length
        end
      end

      module_function

      # @param changed [Boolean] restrict to files in the diff
      # @param base [String, nil] explicit diff base; nil means "work it out"
      # @param root [String] directory to select within
      # @return [Selection]
      # @raise [UsageError] when `--changed` is used outside a git repository.
      #   Typed rather than a crash or a silent empty set: the exit-code
      #   contract makes this a misuse (2), and the CLI maps it later.
      def select(changed: false, base: nil, root: Dir.pwd)
        changed ? select_changed(base: base, root: root) : select_all(root: root)
      end

      # Every `*_spec.rb` under `root`, recursively. Hidden directories are not
      # traversed (no `File::FNM_DOTMATCH`), so `.git` and friends are skipped.
      def select_all(root: Dir.pwd)
        files = Dir.glob(DEFAULT_GLOB, base: root).select { |f| File.file?(File.join(root, f)) }.sort
        Selection.new(files: files, mode: :all)
      end

      def select_changed(base: nil, root: Dir.pwd)
        unless git_repository?(root)
          raise UsageError, "--changed requires a git repository; #{root} is not inside one"
        end

        resolved = base || default_base(root)
        unless resolved
          raise UsageError,
                "--changed could not determine a diff base (no #{DEFAULT_BRANCH_REFS.join(', ')} " \
                "and no HEAD commit); pass --changed=<base> explicitly"
        end

        files = diff_names(resolved, root)
                .select { |f| File.fnmatch?("*_spec.rb", f) }
                .select { |f| File.file?(File.join(root, f)) }
                .sort

        Selection.new(files: files, mode: :changed, base: resolved, note: base ? nil : base_note(resolved, root))
      end

      # `--diff-filter=d` drops deleted paths — `git diff --name-only` lists
      # them, and they then fail to open.
      def diff_names(base, root)
        out, ok = git(%W[diff --name-only --diff-filter=d #{base} --], root)
        raise UsageError, "--changed could not diff against #{base.inspect}" unless ok

        out.split("\n").reject(&:empty?)
      end

      # The merge base of HEAD with the default branch, or nil when there is no
      # usable branch or no HEAD (a repository with no commits yet).
      def default_base(root)
        head, ok = git(%w[rev-parse --verify --quiet HEAD], root)
        return nil unless ok && !head.strip.empty?

        DEFAULT_BRANCH_REFS.each do |ref|
          resolved, found = git(%W[rev-parse --verify --quiet #{ref}], root)
          next unless found && !resolved.strip.empty?

          merge_base, ok = git(%W[merge-base HEAD #{ref}], root)
          return merge_base.strip if ok && !merge_base.strip.empty?
        end

        # Detached from any known default branch: fall back to HEAD, which
        # selects uncommitted work only. Better than selecting everything.
        head.strip
      end

      # Names the default-branch case explicitly so an empty selection reads as
      # "nothing changed here", not "the tool is broken".
      def base_note(resolved, root)
        head, ok = git(%w[rev-parse HEAD], root)
        return nil unless ok && head.strip == resolved

        "the diff base is HEAD itself (this looks like a default-branch build), " \
          "so only uncommitted changes can be selected"
      end

      def git_repository?(root)
        out, ok = git(%w[rev-parse --is-inside-work-tree], root)
        ok && out.strip == "true"
      end

      # Runs git without a shell and without inheriting stderr into our output.
      # @return [[String, Boolean]] stdout and whether git exited 0
      def git(args, root)
        require "open3"
        out, _err, status = Open3.capture3("git", *args, chdir: root)
        [out, status.success?]
      rescue SystemCallError
        # git not installed / not executable.
        ["", false]
      end
    end
  end
end
