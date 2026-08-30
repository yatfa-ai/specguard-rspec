# frozen_string_literal: true

require "tmpdir"
require "open3"

RSpec.describe SpecGuard::RSpec::FileSelector do
  # Real git repositories, not a stubbed `git`. The whole point of this class is
  # what git actually does on a clean checkout, which a stub would simply
  # re-assert rather than test.
  def git(*args, chdir:)
    _out, err, status = Open3.capture3("git", *args, chdir: chdir)
    raise "git #{args.join(' ')} failed: #{err}" unless status.success?
  end

  def write(root, path, contents = "# a spec\n")
    full = File.join(root, path)
    FileUtils.mkdir_p(File.dirname(full))
    File.write(full, contents)
    full
  end

  def commit(root, message)
    git("add", "-A", chdir: root)
    git("commit", "-q", "-m", message, chdir: root)
  end

  def init_repo(root)
    git("init", "-q", "--initial-branch=main", chdir: root)
    git("config", "user.email", "test@example.com", chdir: root)
    git("config", "user.name", "Test", chdir: root)
  end

  around do |example|
    Dir.mktmpdir("specguard-selector") { |dir| example.run(@root = dir) }
  end

  attr_reader :root

  describe "the default selection" do
    # @intent: { entity: "FileSelector", action: "select spec files", behavior: "the default walk finds every spec-named file under the working directory recursively", layer: "unit" }
    it "finds every *_spec.rb under the working directory, recursively" do
      write(root, "spec/models/order_spec.rb")
      write(root, "spec/requests/deeply/nested/checkout_spec.rb")

      expect(described_class.select(root: root).files)
        .to eq(["spec/models/order_spec.rb", "spec/requests/deeply/nested/checkout_spec.rb"])
    end

    # @intent: { entity: "FileSelector", action: "select spec files", behavior: "files not ending in the spec suffix are left out of the selection", layer: "unit" }
    it "ignores files that are not *_spec.rb" do
      write(root, "spec/spec_helper.rb")
      write(root, "app/models/order.rb")
      write(root, "spec/order_spec.rb")

      expect(described_class.select(root: root).files).to eq(["spec/order_spec.rb"])
    end

    # @intent: { entity: "FileSelector", action: "select spec files", behavior: "the walk does not descend into hidden directories", layer: "unit" }
    it "does not descend into hidden directories" do
      write(root, ".git/hooks/order_spec.rb")
      write(root, "spec/order_spec.rb")

      expect(described_class.select(root: root).files).to eq(["spec/order_spec.rb"])
    end

    # @intent: { entity: "FileSelector", action: "select spec files", behavior: "only plain files reach the reader, so a directory named like a spec never leaks through", layer: "unit" }
    it "never hands a directory to the reader" do
      FileUtils.mkdir_p(File.join(root, "spec/weird_spec.rb"))

      expect(described_class.select(root: root).files).to be_empty
    end

    # @intent: { entity: "FileSelector", action: "select spec files", behavior: "a tree with no matching files yields an empty selection rather than a pretend one", layer: "unit" }
    it "reports an empty selection rather than pretending to have work" do
      selection = described_class.select(root: root)

      expect(selection).to be_empty
      expect(selection.count).to eq(0)
    end
  end

  describe "--changed" do
    # THE defect this slice exists to prevent. A CI runner checks out a commit
    # and leaves the tree clean; bare `git diff --name-only` compares the
    # working tree against the index, so it matches nothing and the linter
    # would check zero files while exiting 0 — a CI gate that is silently a
    # no-op. The merge-base default fixes it for the feature-branch case.
    # @intent: { entity: "FileSelector", action: "select changed files", behavior: "on a clean feature-branch checkout the merge-base diff still finds the branch spec files where a bare working-tree diff finds nothing", layer: "unit" }
    it "selects the branch's changes on a clean checkout, where a bare `git diff` finds nothing" do
      init_repo(root)
      write(root, "spec/existing_spec.rb")
      commit(root, "base")
      git("checkout", "-q", "-b", "feature", chdir: root)
      write(root, "spec/added_spec.rb")
      commit(root, "add a spec")

      # Precondition: the tree is clean, exactly as after a CI checkout.
      bare_diff, = Open3.capture2("git", "diff", "--name-only", chdir: root)
      expect(bare_diff).to be_empty

      expect(described_class.select(changed: true, root: root).files).to eq(["spec/added_spec.rb"])
    end

    # @intent: { entity: "FileSelector", action: "select changed files", behavior: "uncommitted edits are picked up because the base is compared against the working tree", layer: "unit" }
    it "also picks up uncommitted work, since the base is compared to the working tree" do
      init_repo(root)
      write(root, "spec/existing_spec.rb")
      commit(root, "base")
      git("checkout", "-q", "-b", "feature", chdir: root)
      File.write(File.join(root, "spec/existing_spec.rb"), "# edited\n")

      expect(described_class.select(changed: true, root: root).files).to eq(["spec/existing_spec.rb"])
    end

    # @intent: { entity: "FileSelector", action: "select changed files", behavior: "the diff is restricted to spec files, leaving other changed paths out", layer: "unit" }
    it "restricts the diff to spec files" do
      init_repo(root)
      write(root, "README.md", "hello\n")
      commit(root, "base")
      git("checkout", "-q", "-b", "feature", chdir: root)
      write(root, "app/models/order.rb", "class Order; end\n")
      write(root, "spec/order_spec.rb")
      commit(root, "change both")

      expect(described_class.select(changed: true, root: root).files).to eq(["spec/order_spec.rb"])
    end

    # `git diff --name-only` lists deleted paths, which then fail to open.
    # @intent: { entity: "FileSelector", action: "select changed files", behavior: "a spec file deleted on the branch is excluded from the selection", layer: "unit" }
    it "excludes deleted spec files" do
      init_repo(root)
      write(root, "spec/gone_spec.rb")
      write(root, "spec/kept_spec.rb")
      commit(root, "base")
      git("checkout", "-q", "-b", "feature", chdir: root)
      FileUtils.rm(File.join(root, "spec/gone_spec.rb"))
      write(root, "spec/kept_spec.rb", "# edited\n")
      commit(root, "delete one, edit one")

      expect(described_class.select(changed: true, root: root).files).to eq(["spec/kept_spec.rb"])
    end

    # @intent: { entity: "FileSelector", action: "select changed files", behavior: "passing an explicit base overrides the merge-base resolution", layer: "unit" }
    it "honours an explicit base" do
      init_repo(root)
      write(root, "spec/one_spec.rb")
      commit(root, "one")
      base, = Open3.capture2("git", "rev-parse", "HEAD", chdir: root)
      write(root, "spec/two_spec.rb")
      commit(root, "two")

      expect(described_class.select(changed: true, base: base.strip, root: root).files)
        .to eq(["spec/two_spec.rb"])
    end

    # The finding the merge-base default does NOT fix, and must therefore be
    # reported rather than hidden: on a default-branch build HEAD == origin/main,
    # so the merge base IS HEAD and nothing legitimately differs.
    # @intent: { entity: "FileSelector", action: "explain an empty selection", behavior: "a default-branch build selects nothing and explains that the merge base is the branch itself", layer: "unit" }
    it "selects nothing on a default-branch build, and says why" do
      init_repo(root)
      write(root, "spec/order_spec.rb")
      commit(root, "base")

      selection = described_class.select(changed: true, root: root)

      expect(selection).to be_empty
      expect(selection.note).to include("default-branch build")
    end

    # @intent: { entity: "FileSelector", action: "explain an empty selection", behavior: "the selection still reports which base it diffed against, so an empty result stays explainable", layer: "unit" }
    it "still reports the base it used, so an empty selection is explainable" do
      init_repo(root)
      write(root, "spec/order_spec.rb")
      commit(root, "base")

      expect(described_class.select(changed: true, root: root).base).not_to be_nil
    end

    # Per the exit-code contract this is a misuse (2). Emitting the code is the
    # next slice; surfacing it as a typed error is this one.
    # @intent: { entity: "FileSelector", action: "fail loudly outside a repo", behavior: "running changed mode outside a git repository raises the typed usage error", layer: "unit" }
    it "raises a typed UsageError outside a git repository" do
      expect { described_class.select(changed: true, root: root) }
        .to raise_error(SpecGuard::RSpec::UsageError, /requires a git repository/)
    end

    # @intent: { entity: "FileSelector", action: "fail loudly outside a repo", behavior: "the outside-a-repository failure raises rather than silently returning an empty set", layer: "unit" }
    it "does not silently return an empty set outside a git repository" do
      write(root, "spec/order_spec.rb")

      expect { described_class.select(changed: true, root: root) }
        .to raise_error(SpecGuard::RSpec::UsageError)
    end

    # @intent: { entity: "FileSelector", action: "fail loudly outside a repo", behavior: "a base ref git cannot resolve raises the typed usage error", layer: "unit" }
    it "raises a typed UsageError for an unresolvable base" do
      init_repo(root)
      write(root, "spec/order_spec.rb")
      commit(root, "base")

      expect { described_class.select(changed: true, base: "no-such-ref", root: root) }
        .to raise_error(SpecGuard::RSpec::UsageError, /could not diff/)
    end

    # @intent: { entity: "FileSelector", action: "fail loudly outside a repo", behavior: "a repository with no commits yet raises the typed usage error instead of selecting", layer: "unit" }
    it "raises a typed UsageError in a repository with no commits yet" do
      init_repo(root)
      write(root, "spec/order_spec.rb")

      expect { described_class.select(changed: true, root: root) }
        .to raise_error(SpecGuard::RSpec::UsageError, /could not determine a diff base/)
    end

    # Every --changed example above passes root: = the repository top level,
    # which is exactly why the two path-handling defects below survived an
    # otherwise thorough suite. `git diff` reports paths relative to the
    # REPOSITORY ROOT; this class returns them relative to `root`. Those are the
    # same string only when you happen to stand at the top level.
    describe "resolving git's repo-root-relative paths" do
      # @intent: { entity: "FileSelector", action: "resolve repo-root-relative paths", behavior: "running from a subdirectory still selects the specs changed under that subtree", layer: "unit" }
      it "selects changed specs when run from a subdirectory of the repository" do
        init_repo(root)
        write(root, "README.md", "hello\n")
        commit(root, "base")
        git("checkout", "-q", "-b", "feature", chdir: root)
        write(root, "sub/spec/child_spec.rb")
        commit(root, "add a nested spec")

        # git says "sub/spec/child_spec.rb"; from sub/ that names nothing.
        selection = described_class.select(changed: true, root: File.join(root, "sub"))

        expect(selection.files).to eq(["spec/child_spec.rb"])
      end

      # @intent: { entity: "FileSelector", action: "resolve repo-root-relative paths", behavior: "returned paths resolve as real files from the root they were selected against", layer: "unit" }
      it "returns paths that actually resolve from the root they were selected against" do
        init_repo(root)
        write(root, "README.md", "hello\n")
        commit(root, "base")
        git("checkout", "-q", "-b", "feature", chdir: root)
        write(root, "sub/spec/child_spec.rb")
        commit(root, "add a nested spec")

        sub = File.join(root, "sub")
        files = described_class.select(changed: true, root: sub).files

        expect(files.map { |f| File.file?(File.join(sub, f)) }).to eq([true])
      end

      # The scoping decision, pinned: --changed is cwd-scoped to match the
      # default mode. A changed spec elsewhere in the repo is excluded — but
      # COUNTED, so the caller can say "outside this directory" instead of the
      # falsehood "nothing in the diff matched".
      # @intent: { entity: "FileSelector", action: "resolve repo-root-relative paths", behavior: "changed specs outside the selection root are excluded but counted as outside, keeping spec_matches honest", layer: "unit" }
      it "excludes changed specs outside the selection root, and counts them" do
        init_repo(root)
        write(root, "README.md", "hello\n")
        commit(root, "base")
        git("checkout", "-q", "-b", "feature", chdir: root)
        write(root, "sub/spec/child_spec.rb")
        write(root, "other/spec/sibling_spec.rb")
        commit(root, "add two specs")

        selection = described_class.select(changed: true, root: File.join(root, "sub"))

        expect(selection.files).to eq(["spec/child_spec.rb"])
        expect(selection.stats.spec_matches).to eq(2)
        expect(selection.stats.outside_root).to eq(1)
      end

      # The same rule as the example above, for the other filter in the same
      # three-way partition. `unreadable` exists so the caller can say "could
      # not be read" instead of guessing at whichever filter it happens to
      # check first; a count nobody produces a spec for is a count nobody
      # notices going wrong. A committed symlink to a missing target is a
      # changed path git reports (so it survives `--diff-filter=d`) that
      # `File.file?` still refuses.
      # @intent: { entity: "FileSelector", action: "resolve repo-root-relative paths", behavior: "changed specs that cannot be read, such as a symlink to a missing target, are excluded and counted as unreadable", layer: "unit" }
      it "excludes changed specs that cannot be read, and counts them" do
        init_repo(root)
        write(root, "README.md", "hello\n")
        commit(root, "base")
        git("checkout", "-q", "-b", "feature", chdir: root)
        write(root, "spec/child_spec.rb")
        File.symlink("missing_target.rb", File.join(root, "spec/broken_spec.rb"))
        commit(root, "add a spec and a broken symlink")

        selection = described_class.select(changed: true, root: root)

        expect(selection.files).to eq(["spec/child_spec.rb"])
        expect(selection.stats.spec_matches).to eq(2)
        expect(selection.stats.unreadable).to eq(1)
      end

      # @intent: { entity: "FileSelector", action: "resolve repo-root-relative paths", behavior: "a sibling directory sharing only a name prefix with the root is excluded rather than half-matched", layer: "unit" }
      it "does not confuse a sibling directory sharing a name prefix with the root" do
        init_repo(root)
        write(root, "README.md", "hello\n")
        commit(root, "base")
        git("checkout", "-q", "-b", "feature", chdir: root)
        write(root, "sub/one_spec.rb")
        write(root, "subterranean/two_spec.rb")
        commit(root, "add two specs")

        selection = described_class.select(changed: true, root: File.join(root, "sub"))

        expect(selection.files).to eq(["one_spec.rb"])
        expect(selection.stats.outside_root).to eq(1)
      end

      # core.quotePath is on by default, so without `-z` git renders
      # spec/café_spec.rb as the literal characters "spec/caf\303\251_spec.rb"
      # — a string that names no file. It was dropped, then misreported as
      # "nothing in the diff matched *_spec.rb".
      # @intent: { entity: "FileSelector", action: "resolve repo-root-relative paths", behavior: "a changed spec with an accented path git would quote is still selected under its real name", layer: "unit" }
      it "selects a changed spec whose path git would quote" do
        init_repo(root)
        write(root, "README.md", "hello\n")
        commit(root, "base")
        git("checkout", "-q", "-b", "feature", chdir: root)
        write(root, "spec/café_spec.rb")
        commit(root, "add an accented spec")

        # Precondition: git really does quote it without -z.
        quoted, = Open3.capture2("git", "diff", "--name-only", "main", "--", chdir: root)
        expect(quoted).to include('"spec/caf')

        expect(described_class.select(changed: true, root: root).files).to eq(["spec/café_spec.rb"])
      end

      # @intent: { entity: "FileSelector", action: "resolve repo-root-relative paths", behavior: "a spec path containing a space arrives as one selection instead of splitting in two", layer: "unit" }
      it "does not let a path with a space split into two selections" do
        init_repo(root)
        write(root, "README.md", "hello\n")
        commit(root, "base")
        git("checkout", "-q", "-b", "feature", chdir: root)
        write(root, "spec/two words_spec.rb")
        commit(root, "add a spaced spec")

        expect(described_class.select(changed: true, root: root).files).to eq(["spec/two words_spec.rb"])
      end
    end

    describe "explaining a thin selection" do
      # Both fallbacks leave the base at HEAD, and they are NOT the same thing:
      # one is a normal default-branch build, the other means --changed has
      # quietly degraded to `git diff HEAD` — the working-tree-vs-HEAD no-op
      # this class exists to avoid. Reporting the first when the second is true
      # is a confidently wrong explanation.
      # @intent: { entity: "FileSelector", action: "explain a thin selection", behavior: "a missing default branch is reported as missing rather than misread as a default-branch build", layer: "unit" }
      it "says the default branch is missing, not that this is a default-branch build" do
        init_repo(root)
        git("checkout", "-q", "-b", "wip", chdir: root)
        write(root, "spec/order_spec.rb")
        commit(root, "base")

        selection = described_class.select(changed: true, root: root)

        expect(selection.note).to include("no default-branch ref")
        expect(selection.note).not_to include("default-branch build")
      end

      # @intent: { entity: "FileSelector", action: "explain a thin selection", behavior: "a merge base that simply equals the branch head is not claimed as a missing default branch", layer: "unit" }
      it "does not claim a missing default branch when the merge base simply is HEAD" do
        init_repo(root)
        write(root, "spec/order_spec.rb")
        commit(root, "base")

        expect(described_class.select(changed: true, root: root).note)
          .not_to include("no default-branch ref")
      end

      # @intent: { entity: "FileSelector", action: "explain a thin selection", behavior: "an ordinary feature-branch selection carries no thin-selection note", layer: "unit" }
      it "does not annotate an ordinary feature-branch selection" do
        init_repo(root)
        write(root, "spec/existing_spec.rb")
        commit(root, "base")
        git("checkout", "-q", "-b", "feature", chdir: root)
        write(root, "spec/added_spec.rb")
        commit(root, "add a spec")

        expect(described_class.select(changed: true, root: root).note).to be_nil
      end

      # @intent: { entity: "FileSelector", action: "explain a thin selection", behavior: "the explanation distinguishes nothing changed at all from changes that matched no spec file", layer: "unit" }
      it "distinguishes 'nothing changed' from 'nothing that changed was a spec'" do
        init_repo(root)
        write(root, "README.md", "hello\n")
        commit(root, "base")
        git("checkout", "-q", "-b", "feature", chdir: root)
        write(root, "app/models/order.rb", "class Order; end\n")
        commit(root, "change a non-spec")

        stats = described_class.select(changed: true, root: root).stats

        expect(stats.changed).to eq(1)
        expect(stats.spec_matches).to eq(0)
      end
    end
  end
end
