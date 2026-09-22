module MapsHelper
  # A map payload's tooltip words as { shape key => tips by variant }, for a
  # <script type="application/json">. json_escape leaves nothing an HTML
  # parser could read as markup, including "</script>". Omits incl_internals
  # when it matches excl_internals (most House districts), so the JS falls
  # back to excl_internals.
  def map_tips_json(payload)
    tips = payload[:groups].flat_map { |group| group[:shapes] }.select(&:tips).to_h do |shape|
      variants = shape.tips
      entry = { excl_internals: variants[:excl_internals] }
      entry[:incl_internals] = variants[:incl_internals] unless variants[:incl_internals] == variants[:excl_internals]
      [ shape.key, entry ]
    end
    json_escape(tips.to_json).html_safe
  end
end
