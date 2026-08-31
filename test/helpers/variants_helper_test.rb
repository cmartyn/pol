require "test_helper"

class VariantsHelperTest < ActionView::TestCase
  include VariantsHelper

  test "each_variant renders the block once per variant, tagged for the CSS" do
    html = each_variant(tag_name: :span) { |variant| variant.to_s }

    assert_includes html, %(<span data-variant="excl_internals">excl_internals</span>)
    assert_includes html, %(<span data-variant="incl_internals">incl_internals</span>)
  end

  test "variant_swap wraps the two values" do
    html = variant_swap("55%", "51%")

    assert_includes html, %(<span data-variant="excl_internals">55%</span>)
    assert_includes html, %(<span data-variant="incl_internals">51%</span>)
  end

  test "forecasts_by_variant falls back to the published row" do
    rows = { excl_internals: :published, incl_internals: nil }
    result = forecasts_by_variant(->(variant) { rows[variant] })

    assert_equal({ excl_internals: :published, incl_internals: :published }, result)
  end
end
