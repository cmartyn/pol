# The internals toggle's rendering vocabulary. Every toggled surface renders
# BOTH variants into the same cached HTML — the page is byte-identical for
# every reader, which is what keeps the fragment caches and the edge cache
# out of the toggle's way — and CSS shows exactly one, keyed off
# html[data-internals] (see app/assets/tailwind/application.css and
# internals_toggle_controller.js). With no JS at all, the excl_internals
# markup shows: the server-rendered default is the editorial default.
module VariantsHelper
  VARIANTS = %i[excl_internals incl_internals].freeze

  # <%= each_variant do |variant| %> ... <% end %> — renders the block once
  # per variant, wrapped in a tag carrying data-variant for the CSS to key
  # on. `tag_name` matters: a table cell's variants want spans, a section's
  # want divs.
  def each_variant(tag_name: :div, css: nil, &block)
    safe_join(VARIANTS.map do |variant|
      content_tag(tag_name, capture(variant, &block), data: { variant: variant }, class: css)
    end)
  end

  # The inline two-span form for a single value: variant_swap("55%", "51%").
  def variant_swap(excl, incl, tag_name: :span)
    safe_join([
      content_tag(tag_name, excl, data: { variant: :excl_internals }),
      content_tag(tag_name, incl, data: { variant: :incl_internals })
    ])
  end

  # The forecast rows a page should show for a race, keyed by variant, with
  # the published row standing in wherever the internals row is missing —
  # runs from before the dual-variant model wrote only one row, and the
  # toggle degrading to "same numbers" beats a hole in the page.
  def forecasts_by_variant(fetch)
    excl = fetch.call(:excl_internals)
    incl = fetch.call(:incl_internals) || excl
    { excl_internals: excl, incl_internals: incl }
  end
end
