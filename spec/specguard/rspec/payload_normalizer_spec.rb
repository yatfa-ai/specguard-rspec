# frozen_string_literal: true

RSpec.describe SpecGuard::RSpec::PayloadNormalizer do
  def normalize(raw)
    described_class.normalize(raw)
  end

  def round_trip(raw)
    JSON.parse(normalize(raw))
  end

  describe "PROTOCOL.md §1's three equivalent forms" do
    it "passes strict JSON through unchanged" do
      raw = '{ "entity": "Order", "layer": "request" }'

      expect(normalize(raw)).to eq(raw)
    end

    it "converts single-quoted keys and strings" do
      expect(round_trip("{ 'entity': 'Order' }")).to eq("entity" => "Order")
    end

    it "quotes unquoted keys" do
      expect(round_trip('{entity:"Order",action:"checkout"}')).to eq("entity" => "Order", "action" => "checkout")
    end

    it "tolerates arbitrary whitespace, including between a key and its colon" do
      expect(round_trip("{  entity   :   'Order'  }")).to eq("entity" => "Order")
    end

    it "produces identical output for all three forms" do
      results = [
        round_trip('{ "entity": "Order", "layer": "request" }'),
        round_trip("{ entity: 'Order', layer: 'request' }"),
        round_trip('{entity:"Order",layer:"request"}')
      ]

      expect(results.uniq.length).to eq(1)
    end
  end

  describe "quoted content is never rewritten" do
    # This is the property that makes the scanner a scanner. Each of these
    # would be corrupted by a regex substitution over the whole payload.
    it "leaves a colon inside a value alone" do
      expect(round_trip('{behavior: "returns 402: payment required"}'))
        .to eq("behavior" => "returns 402: payment required")
    end

    it "leaves a comma inside a value alone" do
      expect(round_trip('{behavior: "sums prices, then applies the discount"}'))
        .to eq("behavior" => "sums prices, then applies the discount")
    end

    it "leaves a word that looks like a key inside a value alone" do
      expect(round_trip('{behavior: "the entity: field is required"}'))
        .to eq("behavior" => "the entity: field is required")
    end

    it "leaves braces inside a value alone" do
      expect(round_trip('{behavior: "renders the {error} slot"}'))
        .to eq("behavior" => "renders the {error} slot")
    end

    it "leaves an apostrophe inside a double-quoted value alone" do
      expect(round_trip(%({behavior: "the gateway's reason"}))).to eq("behavior" => "the gateway's reason")
    end
  end

  describe "trailing commas" do
    it "drops a trailing comma before }" do
      expect(round_trip("{entity: 'Order', }")).to eq("entity" => "Order")
    end

    it "drops a trailing comma before ]" do
      expect(round_trip("{preconditions: ['a', ]}")).to eq("preconditions" => ["a"])
    end

    it "keeps a comma that separates members" do
      expect(round_trip("{a: 'x', b: 'y'}")).to eq("a" => "x", "b" => "y")
    end

    it "keeps a comma inside a quoted value even when followed by a brace" do
      expect(round_trip('{behavior: "a, }"}')).to eq("behavior" => "a, }")
    end
  end

  describe ".requote" do
    it "unescapes \\' — it is meaningless in JSON" do
      expect(described_class.requote("card\\'s")).to eq('"card\'s"')
    end

    it "escapes a double quote so the re-emitted string stays valid" do
      expect(round_trip(%q({behavior: 'says "hi"'}))).to eq("behavior" => 'says "hi"')
    end

    it "preserves every other escape verbatim" do
      expect(round_trip(%q({behavior: 'a\nb'}))).to eq("behavior" => "a\nb")
    end

    it "preserves an escaped backslash" do
      expect(round_trip(%q({behavior: 'a\\\\b'}))).to eq("behavior" => "a\\b")
    end

    it "handles a trailing lone backslash without running off the end" do
      expect { described_class.requote("abc\\") }.not_to raise_error
    end
  end

  describe "non-string values" do
    it "leaves numbers, booleans and null alone" do
      expect(round_trip("{count: 3, ok: true, extra: null}"))
        .to eq("count" => 3, "ok" => true, "extra" => nil)
    end

    # `true` in *key* position is a bare word like any other, so it is quoted;
    # in value position it must stay a JSON literal.
    it "does not quote a bare true in value position" do
      expect(normalize("{ok: true}")).to eq('{"ok": true}')
    end
  end

  it "raises on an unterminated string literal" do
    expect { normalize("{entity: 'Order}") }.to raise_error(SpecGuard::RSpec::ScanError)
  end
end
