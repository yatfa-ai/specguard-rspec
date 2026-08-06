# frozen_string_literal: true

RSpec.describe SpecGuard::RSpec::AnnotationScanner do
  def intents(text)
    described_class.each_intent(text).to_a
  end

  describe ".each_intent" do
    it "reports the 1-based line number of each annotation" do
      text = "line one\n# @intent: {a: 1}\nline three\n# @intent: {b: 2}\n"

      expect(intents(text).map(&:first)).to eq([2, 4])
    end

    it "returns the payload exactly as written, still in permissive syntax" do
      _, raw, = intents("# @intent: {entity: 'Order'}").first

      expect(raw).to eq("{entity: 'Order'}")
    end

    it "finds a second annotation in the trailing prose of the same line" do
      text = %(# @intent: {a: 1} and also @intent: {b: 2})

      expect(intents(text).map { |_, raw, _| raw }).to eq(["{a: 1}", "{b: 2}"])
    end

    it "does not rescan the captured payload for a nested token" do
      text = %(# @intent: { behavior: "mentions @intent: {nope} in prose" })

      expect(intents(text).length).to eq(1)
    end

    it "returns an Enumerator without a block" do
      expect(described_class.each_intent("# @intent: {a: 1}")).to be_a(Enumerator)
    end

    it "yields nothing for a file with no annotations" do
      expect(intents("RSpec.describe Order do\nend\n")).to be_empty
    end

    it "is not confused by a file with no trailing newline" do
      expect(intents("# @intent: {a: 1}").length).to eq(1)
    end

    context "when an annotation cannot be captured" do
      it "reports a token with nothing after it" do
        _, raw, problem = intents("# @intent:").first

        expect(raw).to be_nil
        expect(problem).to eq("no '{...}' object literal follows the @intent: token")
      end

      it "reports a token followed by prose but no object literal" do
        _, _, problem = intents("# @intent: see the other spec").first

        expect(problem).to eq("no '{...}' object literal follows the @intent: token")
      end

      it "reports a payload that runs off the end of the line" do
        _, _, problem = intents(%(# @intent: { entity: "Order", action: "total",)).first

        expect(problem).to eq("unterminated object literal (an annotation must fit on one line)")
      end

      # The string scan fails before the object scan can, so the reason names
      # the string rather than the object — the more specific diagnosis, and
      # what the reference implementation reports too.
      it "reports an unterminated string inside the payload" do
        _, _, problem = intents(%(# @intent: { entity: "Order })).first

        expect(problem).to eq(%(unterminated "-quoted string))
      end

      it "reports mismatched brackets" do
        _, _, problem = intents("# @intent: {entity: [1}").first

        expect(problem).to eq("unbalanced brackets in the annotation payload")
      end

      # Bailing out of the whole *file* on one bad line would hide every later
      # annotation; bailing out of the rest of the *line* is what the reference
      # does, since the line's structure is already untrustworthy.
      it "stops scanning the broken line but carries on with the next one" do
        text = "# @intent: { oops\n# @intent: {a: 1}\n"
        results = intents(text)

        expect(results.length).to eq(2)
        expect(results[0][2]).not_to be_nil
        expect(results[1][1]).to eq("{a: 1}")
      end
    end
  end

  describe ".scan_object" do
    it "returns the index just past the matching brace" do
      text = "xx{a}yy"

      expect(described_class.scan_object(text, 2)).to eq(5)
    end

    it "balances nested arrays and objects" do
      text = %({ preconditions: ["a {", "b"], nested: {x: 1} })

      expect(described_class.scan_object(text, 0)).to eq(text.length)
    end

    it "raises on an unterminated literal" do
      expect { described_class.scan_object("{a: 1", 0) }.to raise_error(SpecGuard::RSpec::ScanError)
    end
  end

  describe ".scan_string" do
    it "returns the index just past the closing quote" do
      expect(described_class.scan_string(%("ab"c), 0, '"')).to eq(4)
    end

    it "honours a backslash escape so an escaped quote does not terminate it" do
      expect(described_class.scan_string(%("a\\"b"), 0, '"')).to eq(6)
    end

    it "raises on an unterminated string" do
      expect { described_class.scan_string(%("abc), 0, '"') }
        .to raise_error(SpecGuard::RSpec::ScanError, /unterminated/)
    end
  end
end
