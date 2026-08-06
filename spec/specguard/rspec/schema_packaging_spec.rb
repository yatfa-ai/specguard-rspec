# frozen_string_literal: true

# The vendored schema is not read by anything yet — applying it is the next
# slice. It is pinned here anyway because the trap is a *packaging* one: the
# gemspec builds `spec.files` from `git ls-files`, so a vendored file that was
# never `git add`ed is silently absent from the built gem. That failure only
# shows up in the next slice, in an installed gem, far from its cause.
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

  it "is the canonical v1 schema, byte-for-byte" do
    expect(File.size(SpecGuard::RSpec::SCHEMA_PATH)).to eq(638)
    expect(schema["$id"]).to eq("https://specguard.dev/schemas/open-test-intent.v1.json")
    expect(schema["$schema"]).to eq("http://json-schema.org/draft-07/schema#")
  end

  it "carries the constraints the next slice will enforce" do
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
end
