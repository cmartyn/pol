module MapsHelper
  # A map payload's tooltip words as { shape key => tips by variant }, for a
  # <script type="application/json">. json_escape leaves nothing an HTML
  # parser could read as markup, including "</script>".
  def map_tips_json(payload)
    tips = payload[:groups].flat_map { |group| group[:shapes] }.select(&:tips).to_h { |shape| [ shape.key, shape.tips ] }
    json_escape(tips.to_json).html_safe
  end
end
