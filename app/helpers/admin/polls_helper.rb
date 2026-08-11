module Admin
  module PollsHelper
    # Every candidate, grouped into <optgroup>s by race. Senate-only in
    # practice (Phase 2 seeds no House candidates), so this is at most ~35
    # groups of 2-3 — small enough to just show every race's candidates
    # rather than needing JS to scope the list down to whichever race the
    # editor already picked. The race name in the group label IS the
    # scoping; the editor picks from the right group by hand.
    def admin_candidate_options(selected_id = nil, prompt: "—")
      races = Race.joins(:candidates).distinct.includes(:candidates).order(:office, :state, :district)
      grouped = races.to_h { |race| [ race.name, race.candidates.sort_by(&:name).map { |c| [ c.name, c.id ] } ] }
      grouped_options_for_select(grouped, selected_id, prompt: prompt)
    end

    def admin_race_select_options(selected_id = nil, prompt: "Generic ballot (no race)")
      grouped = Race.order(:office, :state, :district).group_by { |race| race.office.capitalize }
                    .transform_values { |races| races.map { |race| [ race.name, race.id ] } }
      grouped_options_for_select(grouped, selected_id, prompt: prompt)
    end

    def admin_population_select_options(selected = nil, prompt: "—")
      options_for_select([ [ prompt, "" ] ] + Poll.populations.keys.map { |key| [ key.upcase, key ] }, selected.presence)
    end

    def admin_entry_mode_badge_color(entry_mode)
      { "scraped" => "bg-slate-100 text-slate-700", "manual" => "bg-blue-50 text-blue-700", "csv" => "bg-purple-50 text-purple-700" }
        .fetch(entry_mode, "bg-slate-100 text-slate-700")
    end

    # The plain D-minus-R convention (not Site::RaceSides' per-race side
    # mapping — this table spans every race at once, including the
    # generic ballot with no race at all, so one consistent sign reads
    # better here than a per-row side flip would), or nil when either
    # party's result is missing from this poll.
    def admin_poll_margin(poll)
      dem = poll.poll_results.find { |result| result.party == "dem" }&.pct
      rep = poll.poll_results.find { |result| result.party == "rep" }&.pct
      return nil if dem.nil? || rep.nil?

      Site::Format.margin(dem - rep, side_a_party: "dem", side_b_party: "rep")
    end

    # poll.source_url is stored free-form (Poll validates only its
    # presence — scraped rows trust Wikipedia's own links, but manual entry
    # and CSV import both accept whatever an editor typed). Rendering it
    # straight into link_to's href is exactly the shape Brakeman's
    # LinkToHref check warns about: a stored value, not a literal, used as
    # a URL — javascript:/data: schemes render fine and execute on click.
    # Both admin poll views that link to a source go through here instead
    # of calling link_to on the raw column directly, so a non-http(s) value
    # renders as inert text rather than a clickable href built from it.
    def safe_external_link(url, text = url, **html_options)
      if url.to_s.match?(%r{\Ahttps?://}i)
        link_to text, url, **html_options
      else
        content_tag(:span, text, class: html_options[:class], data: html_options[:data])
      end
    end
  end
end
