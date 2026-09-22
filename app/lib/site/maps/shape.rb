module Site
  module Maps
    # One drawable region of a map payload. `fills` and `tips` are keyed by
    # forecast variant; `slug` and `tips` are nil for a shape that isn't a
    # link (no race there, or a locator).
    Shape = Struct.new(:key, :d, :slug, :cx, :cy, :fills, :tips, keyword_init: true)
  end
end
