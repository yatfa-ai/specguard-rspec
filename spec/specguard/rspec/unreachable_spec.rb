# frozen_string_literal: true

RSpec.describe SpecGuard::RSpec::Scanner do
  describe ".unreachable_findings_in_text (SPGD-900: the stacked-annotation structural pass)" do
    def findings(text)
      described_class.unreachable_findings_in_text(text, file: "order_spec.rb")
    end

    # @intent: { entity: "Scanner", action: "detect stacked annotations", behavior: "two consecutive comment-form annotations yield exactly one unreachable finding, reported on the upper line with kind unreachable", layer: "unit" }
    it "flags the UPPER line of two consecutive comment-form @intent: lines" do
      text = <<~RUBY
        # @intent: { entity: "Order", behavior: "decrements stock" }
        # @intent: { entity: "Refund", behavior: "restores stock" }
        it "restores stock on refund" do
          expect(order.stock).to eq(3)
        end
      RUBY

      expect(findings(text).length).to eq(1)
      expect(findings(text).first.line).to eq(1)
      expect(findings(text).first.kind).to eq(SpecGuard::RSpec::Finding::KIND_UNREACHABLE)
    end

    # @intent: { entity: "Scanner", action: "detect stacked annotations", behavior: "a run of three comment-form annotations flags every line except the last, at relative lines one and two", layer: "unit" }
    it "flags each line except the last of a run of three stacked annotations" do
      text = <<~RUBY
        # @intent: { entity: "A" }
        # @intent: { entity: "B" }
        # @intent: { entity: "C" }
        it "works" do end
      RUBY

      expect(findings(text).map(&:line)).to eq([1, 2])
    end

    # @intent: { entity: "Scanner", action: "spare the canonical form", behavior: "one comment annotation directly above its example produces no unreachable finding", layer: "unit" }
    it "does not flag the canonical one-comment-above-one-it form" do
      text = <<~RUBY
        # @intent: { entity: "Order", behavior: "decrements stock" }
        it "decrements stock" do end
      RUBY

      expect(findings(text)).to be_empty
    end

    # @intent: { entity: "Scanner", action: "spare trailing-form lines", behavior: "adjacent one-line examples carrying same-line annotations produce no unreachable findings", layer: "unit" }
    it "does not flag the trailing same-line form, even on adjacent one-liners" do
      text = <<~RUBY
        it { is_expected.to eq(1) } # @intent: { entity: "A" }
        it { is_expected.to be_positive } # @intent: { entity: "B" }
      RUBY

      expect(findings(text)).to be_empty
    end

    # @intent: { entity: "Scanner", action: "spare mixed forms", behavior: "a comment annotation above a line that also carries a trailing annotation is not flagged, the stacked rule covering comment-form pairs only", layer: "unit" }
    it "does not flag a comment-form annotation above a trailing-form line" do
      # The stacked rule is comment-form pairs only (SPGD-900's fix): a
      # comment-form annotation above a trailing-form line may be dead too,
      # but that shape is out of scope and must not over-match.
      text = <<~RUBY
        # @intent: { entity: "A" }
        it { is_expected.to eq(1) } # @intent: { entity: "B" }
      RUBY

      expect(findings(text)).to be_empty
    end

    # @intent: { entity: "Scanner", action: "spare separated annotations", behavior: "two comment annotations split by a plain non-intent comment are both reachable and produce no findings", layer: "unit" }
    it "does not flag separated comment annotations separated by a plain comment" do
      text = <<~RUBY
        # @intent: { entity: "A" }
        # rubocop:disable Style/... (not an intent)
        # @intent: { entity: "B" }
        it "works" do end
      RUBY

      expect(findings(text)).to be_empty
    end

    # @intent: { entity: "Scanner", action: "word the finding", behavior: "the unreachable finding carries a problem sentence naming the one-line lookback", layer: "unit" }
    it "carries a problem sentence naming the one-line lookback" do
      text = "# @intent: { entity: \"A\" }\n# @intent: { entity: \"B\" }\nit \"x\" do end\n"

      expect(findings(text).first.problem).to include("unreachable annotation")
    end
  end

  describe ".unreachable_findings_in_file" do
    # @intent: { entity: "Scanner", action: "read a missing file", behavior: "asking for unreachable findings on a path that does not exist returns an empty list rather than raising", layer: "unit" }
    it "contributes nothing for a file that cannot be read" do
      expect(described_class.unreachable_findings_in_file("/nonexistent/order_spec.rb")).to eq([])
    end
  end
end
