require "test_helper"

class MapsHelperTest < ActionView::TestCase
  include ERB::Util

  def tip(overrides = {})
    { header: "Maine Senate", subheader: "Likely D", rows: [], footer: nil }.merge(overrides)
  end

  test "map_tips_json omits incl_internals when both variants match" do
    same = Site::Maps::Shape.new(key: "ME", d: "M0,0z", tips: { excl_internals: tip, incl_internals: tip })
    different = Site::Maps::Shape.new(
      key: "FL", d: "M1,1z",
      tips: { excl_internals: tip, incl_internals: tip(subheader: "Likely R") }
    )
    payload = { groups: [ { shapes: [ same, different ] } ] }
    parsed = JSON.parse(map_tips_json(payload))

    assert_equal [ "excl_internals" ], parsed["ME"].keys
    assert_equal %w[excl_internals incl_internals].sort, parsed["FL"].keys.sort
  end

  test "map_tips_json escapes a header that contains a closing script tag" do
    tips = { excl_internals: tip(header: "</script><img>"), incl_internals: tip(header: "</script><img>") }
    shape = Site::Maps::Shape.new(key: "ME", d: "M0,0z", tips: tips)
    output = map_tips_json({ groups: [ { shapes: [ shape ] } ] })

    assert_no_match(%r{</script>}, output)
  end
end
