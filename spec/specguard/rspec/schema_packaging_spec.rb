# frozen_string_literal: true

require "tmpdir"
require "open3"
require "digest"
require "rubygems/package"

# The vendored schema is now load-bearing: {SpecGuard::RSpec::Schema.load}
# reads it on every run, and a run that cannot read it exits 2. That makes the
# *packaging* trap real rather than theoretical — the gemspec builds
# `spec.files` from `git ls-files`, so a vendored file that was never
# `git add`ed is silently absent from the built gem, and the failure surfaces
# only in an installed gem on someone else's machine, far from its cause.
RSpec.describe "the vendored OpenTestIntent schema" do
  subject(:schema) { JSON.parse(File.read(SpecGuard::RSpec::SCHEMA_PATH)) }

  it "ships inside lib/, which the gemspec packages" do
    expect(SpecGuard::RSpec::SCHEMA_PATH).to include("/lib/specguard/rspec/schemas/")
    expect(File).to exist(SpecGuard::RSpec::SCHEMA_PATH)
  end

  it "is tracked by git, without which it would not be packaged" do
    tracked = `git ls-files --error-unmatch #{SpecGuard::RSpec::SCHEMA_PATH} 2>/dev/null`

    expect(tracked.strip).not_to be_empty
  end

  # The digest of open-test-intent's schemas/open-test-intent.v1.json at the
  # immutable `schema-v1` tag, the copy this file was vendored from — and the
  # same pin open-test-intent's own schema_test.go holds as CanonicalV1SHA256.
  # A byte count would not say this: any same-length edit — swapping an enum
  # member, moving a digit of `minLength` — passes a size check while changing
  # what the linter enforces.
  CANONICAL_V1_SHA256 = "861c82e5dacd8858ef441a505818c503ea289858c62bcb6788ff27dd148508c6"

  # `$id` is pinned as a literal, not derived from anything, precisely because
  # the last one was wrong for the whole life of the project: it named a host
  # that never existed, and an assertion that read the value out of the file it
  # was checking would have agreed with it every single day. It now names the
  # protocol repository at a tag that is cut once and never moved, so this
  # string is both the identifier and a fetchable address for these bytes.
  CANONICAL_V1_ID = "https://raw.githubusercontent.com/yatfa-ai/open-test-intent/schema-v1/schemas/open-test-intent.v1.json"

  it "is the canonical v1 schema, byte-for-byte" do
    expect(Digest::SHA256.file(SpecGuard::RSpec::SCHEMA_PATH).hexdigest).to eq(CANONICAL_V1_SHA256)
    expect(schema["$id"]).to eq(CANONICAL_V1_ID)
    expect(schema["$schema"]).to eq("http://json-schema.org/draft-07/schema#")
  end

  it "carries the constraints the linter enforces" do
    expect(schema["additionalProperties"]).to be(false)
    expect(schema["required"]).to contain_exactly("entity", "action", "behavior", "layer")
    expect(schema.dig("properties", "behavior", "minLength")).to eq(15)
    expect(schema.dig("properties", "layer", "enum")).to eq(%w[unit integration request system])
  end

  # The fixtures are excluded from the gem by design, so nothing at runtime may
  # depend on them. This is the assertion that keeps that true.
  it "is reachable without the spec fixtures, which do not ship" do
    expect(SpecGuard::RSpec::SCHEMA_PATH).not_to include("/spec/")
  end

  # Criterion 9 + trap (b). Only an actual `gem build` proves `spec.files`
  # resolved the way the gemspec's `git ls-files` intended — reading the
  # gemspec cannot, because the trap is about what git knows, not about what
  # the file says.
  describe "the built gem" do
    # `gem build` shells out, so it runs once for the whole group.
    before(:context) do
      root = File.expand_path("../../..", __dir__)
      @build_dir = Dir.mktmpdir("specguard-gem")
      gem_file = File.join(@build_dir, "built.gem")

      out, err, status = Open3.capture3("gem", "build", "specguard-rspec.gemspec", "--output", gem_file,
                                        chdir: root)
      raise "gem build failed:\n#{out}\n#{err}" unless status.success?

      @spec = Gem::Package.new(gem_file).spec
    end

    after(:context) { FileUtils.remove_entry(@build_dir) if @build_dir }

    it "builds, and is named and versioned as expected" do
      expect(@spec.name).to eq("specguard-rspec")
      expect(@spec.version.to_s).to eq(SpecGuard::RSpec::VERSION)
    end

    it "packages the vendored schema, which the linter cannot run without" do
      expect(@spec.files).to include("lib/specguard/rspec/schemas/open-test-intent.v1.json")
    end

    # The schema is not the only file the trap can eat. `git ls-files` misses
    # ANY untracked file, and an untracked `lib/**.rb` produces a LoadError in
    # the installed gem — reproduced during this ticket, before these files
    # were added. Enumerating the tree rather than naming files keeps the next
    # person who adds one honest without their having to remember this spec.
    it "packages every Ruby file under lib/, not just the ones named here" do
      root = File.expand_path("../../..", __dir__)
      on_disk = Dir.glob("lib/**/*.rb", base: root).sort

      expect(@spec.files & on_disk).to match_array(on_disk)
    end

    # Both of them, and pinned as a whole list rather than with `include`: an
    # executable declared in `spec.executables` but absent from `spec.files` is
    # installed as a broken shim, and one added to `bin/` but never declared is
    # not installed at all. `spec.files` comes from `git ls-files`, so the
    # second shape is one `git add` away at any time — this example is what
    # caught `bin/specguard-ingest` while it was still untracked (SPGD-631).
    it "packages both executables" do
      expect(@spec.executables).to match_array(%w[specguard-lint specguard-ingest])
      expect(@spec.files).to include("bin/specguard-lint", "bin/specguard-ingest")
    end

    it "does not package the spec fixtures, so they can never become load-bearing" do
      expect(@spec.files.grep(%r{^spec/})).to be_empty
    end

    it "declares json_schemer, the gem's first runtime dependency" do
      dependency = @spec.runtime_dependencies.find { |d| d.name == "json_schemer" }

      expect(dependency).not_to be_nil
      expect(dependency.requirement.to_s).to eq("~> 2.5")
    end
  end

  # The end of the trap: prove the packaged gem's own copy of the schema is
  # loadable, standing outside the source checkout so no stray relative path
  # can rescue it.
  describe "the schema as the installed gem would see it" do
    it "loads from the packaged copy" do
      Dir.mktmpdir do |dir|
        packaged = File.join(dir, "open-test-intent.v1.json")
        FileUtils.cp(SpecGuard::RSpec::SCHEMA_PATH, packaged)

        expect(SpecGuard::RSpec::Schema.load(packaged).document).to eq(schema)
      end
    end
  end
end
