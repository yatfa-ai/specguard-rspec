# frozen_string_literal: true

require "tmpdir"

RSpec.describe SpecGuard::RSpec::Schema do
  describe ".load" do
    it "loads the vendored canonical schema" do
      schema = described_class.load

      expect(schema.document["$id"]).to eq("https://specguard.dev/schemas/open-test-intent.v1.json")
    end

    # Every way loading can fail must arrive as ONE exception type, because the
    # CLI maps that type to exit 2. If any of these escaped as its own class,
    # the generic backstop would still catch it — but the message would be
    # "internal error", not the reference tool's "could not load schema".
    it "retypes a missing file as SchemaError" do
      expect { described_class.load("/nonexistent/schema.json") }
        .to raise_error(SpecGuard::RSpec::SchemaError, %r{could not load schema /nonexistent/schema\.json: })
    end

    it "retypes unparseable JSON as SchemaError" do
      Dir.mktmpdir do |dir|
        path = File.join(dir, "schema.json")
        File.write(path, "{ not json")

        expect { described_class.load(path) }.to raise_error(SpecGuard::RSpec::SchemaError)
      end
    end

    # json_schemer is permissive about nonsense in a schema: `{"type": 42}`
    # compiles and is then treated as no constraint at all, so a corrupted
    # vendored schema would produce a linter that accepts EVERY annotation and
    # reports a clean run. Meta-validating at load turns that into an exit 2.
    it "retypes a document that parses but is not a valid draft-07 schema as SchemaError" do
      Dir.mktmpdir do |dir|
        path = File.join(dir, "schema.json")
        File.write(path, '{"type": 42}')

        expect { described_class.load(path) }
          .to raise_error(SpecGuard::RSpec::SchemaError, /not a valid draft-07 schema/)
      end
    end

    it "retypes a schema whose breakage only surfaces during validation" do
      Dir.mktmpdir do |dir|
        path = File.join(dir, "schema.json")
        # Compiles fine; raises NoMethodError from inside the first #validate.
        File.write(path, '{"type": "object", "required": "nope"}')

        expect { described_class.load(path) }.to raise_error(SpecGuard::RSpec::SchemaError)
      end
    end

    it "does not silently accept everything when the schema is corrupt" do
      Dir.mktmpdir do |dir|
        path = File.join(dir, "schema.json")
        File.write(path, '{"type": "object", "properties": {"layer": {"enum": "unit"}}}')

        expect { described_class.load(path) }.to raise_error(SpecGuard::RSpec::SchemaError)
      end
    end

    it "retypes a directory handed in place of a file as SchemaError" do
      Dir.mktmpdir do |dir|
        expect { described_class.load(dir) }.to raise_error(SpecGuard::RSpec::SchemaError)
      end
    end

    # SchemaError must not be a UsageError: they mean different things (the
    # tool is broken vs the caller is), print different words, and only
    # coincidentally share an exit code.
    it "is not a UsageError, which reports itself differently" do
      expect(SpecGuard::RSpec::SchemaError.ancestors).not_to include(SpecGuard::RSpec::UsageError)
      expect(SpecGuard::RSpec::SchemaError.ancestors).to include(SpecGuard::RSpec::Error)
    end
  end

  describe "#violations" do
    subject(:schema) { described_class.load }

    it "is empty for a valid annotation" do
      expect(schema.violations(payload_fixture("unit-order-total.json"))).to be_empty
    end

    it "reports a non-object payload rather than accepting it" do
      expect(schema.violations(["not", "an", "object"])).to eq(["<root>: expected type object, got array"])
    end
  end
end
