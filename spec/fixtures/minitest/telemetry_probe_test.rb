# frozen_string_literal: true

# A minitest suite with one of each outcome, driven end to end by
# plugin_spec.rb against a local capture server. Not named `*_spec.rb` on
# purpose: RSpec's default pattern must not adopt it into this repository's
# own suite. One test carries a schema-valid annotation so the wire envelope
# proves attachment, not merely the unannotated floor.
require "minitest/autorun"

class TelemetryProbeTest < Minitest::Test
  def test_passes
    assert_equal 1, 1
  end

  # @intent: { entity: "TelemetryProbe", action: "prove attachment", behavior: "the plugin ships this test's annotation with its row", layer: "integration" }
  def test_annotated
    assert_equal 1, 1
  end

  def test_fails
    assert_equal 1, 2
  end

  def test_skips
    skip "deliberately not answered"
  end
end
