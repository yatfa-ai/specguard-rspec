# frozen_string_literal: true

# Proves the gem loads and reserves the SpecGuard::RSpec namespace. The real
# linter/formatter behavior is Phase 5 (see ticket SPGD-37); this skeleton
# only needs to demonstrate the gem is requireable and versioned.
RSpec.describe SpecGuard::RSpec do
  it "defines SpecGuard::RSpec::VERSION" do
    expect(SpecGuard::RSpec::VERSION).to eq("0.1.0")
  end
end
