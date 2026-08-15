module RacesHelper
  PARTY_TEXT_COLOR = {
    "dem" => "text-blue-700",
    "rep" => "text-red-700",
    "other" => "text-slate-700"
  }.freeze

  PARTY_CHIP_COLOR = {
    "dem" => "bg-blue-50 text-blue-700",
    "rep" => "bg-red-50 text-red-700",
    "other" => "bg-slate-100 text-slate-700"
  }.freeze

  PARTY_LETTER = { "dem" => "D", "rep" => "R", "other" => "Ind" }.freeze

  # [side_a_party, side_b_party] ("dem"/"rep"/"ind"/"other") for a race, from
  # its preloaded candidates — see Site::RaceSides for why this isn't always
  # just "dem"/"rep".
  def race_sides(race)
    Site::RaceSides.for(race.candidates)
  end

  # A margin value (side_a - side_b, in points) formatted as "D+3.2" and
  # colored to match, or nil (render your own empty state) when there's no
  # value yet.
  def formatted_margin(race, value)
    return nil if value.nil?

    Site::Format.margin(value, side_a_party: race_sides(race).first, side_b_party: race_sides(race).second)
  end

  # Which party a margin value should be colored as — "other" (neutral) for
  # a value that rounds to Even, matching Site::Format.margin's own zero
  # handling rather than defaulting to side_b.
  def margin_party(race, value)
    return nil if value.nil?

    side_a, side_b = race_sides(race)
    rounded = value.round(1)
    return "other" if rounded.zero?

    rounded.positive? ? side_a : side_b
  end

  # House-only formatting that deliberately bypasses race_sides/
  # Site::RaceSides: every modelled House race runs on the generic dem/rep
  # sides (Phase 2 seeds no House candidates at all, and
  # Forecast::RaceModel#side_a/#side_b fall back to the bare party when
  # there's no candidate to name — see Site::HouseTable's header comment).
  # Going through race.candidates here would lazy-load it per row, turning
  # the House table's carefully-bounded 3 queries back into an N+1 — which
  # is exactly the bug a controller-level test with extra ad-hoc districts
  # caught. dem/rep is not a shortcut standing in for the real answer; for
  # House it structurally *is* the real answer.
  def house_margin(value)
    return nil if value.nil?

    Site::Format.margin(value, side_a_party: "dem", side_b_party: "rep")
  end

  def house_margin_party(value)
    return nil if value.nil?

    rounded = value.round(1)
    return "other" if rounded.zero?

    rounded.positive? ? "dem" : "rep"
  end

  # The rating word a race's row/header should show. "Uncontested" is a
  # Race-level fact Site::Format can't see, so it's decided here, ahead of
  # the Tossup/Favors-{Party} call Site::Format makes from the forecast's
  # three win probabilities.
  def rating_word_for(race, forecast)
    return "Uncontested" if race.uncontested? && race.uncontested_party.present?
    return nil unless forecast

    Site::Format.rating_word(
      p_dem_win: forecast.p_dem_win, p_rep_win: forecast.p_rep_win, p_other_win: forecast.p_other_win,
      tossup_band_pp: Pol::Params.fetch!(:site, :tossup_band_pp)
    )
  end

  # "dem" / "rep" / "other" — whichever of the forecast's three win
  # probabilities is highest. "other" covers both independents and minor
  # parties; the forecast itself doesn't distinguish them (Forecast::
  # Simulator#key_for), so neither does this.
  def leading_party(forecast)
    win_probabilities(forecast).max_by { |_, probability| probability }.first
  end

  def leading_probability(forecast)
    win_probabilities(forecast).fetch(leading_party(forecast))
  end

  # A small colored "D 62%" / "R 97%" pill — the win-probability chip the
  # Senate and House tables show per row.
  def probability_chip(forecast)
    return content_tag(:span, "No forecast yet", class: "text-slate-400 text-sm", data: { testid: "probability-chip" }) unless forecast

    party = leading_party(forecast)
    classes = "inline-flex items-center gap-1 rounded-full px-2.5 py-0.5 text-sm font-semibold #{PARTY_CHIP_COLOR.fetch(party)}"
    content_tag(:span, "#{PARTY_LETTER.fetch(party)} #{Site::Format.percent(leading_probability(forecast))}",
                class: classes, data: { testid: "probability-chip" })
  end

  def party_text_color(party)
    PARTY_TEXT_COLOR.fetch(party.to_s, "text-slate-700")
  end

  # The margin a single poll shows for a race: top result for each side,
  # minus the other, formatted the same way every other margin on the site
  # is. nil when the poll has no result for one of the two sides (rare —
  # see Site::Charts::PollsScatter for why it can happen).
  def poll_margin(poll, race)
    value = poll_margin_value(poll, race)
    return nil if value.nil?

    side_a, side_b = race_sides(race)
    rounded = value.round(1)
    party = rounded.zero? ? "other" : (rounded.positive? ? side_a : side_b)
    { label: Site::Format.margin(value, side_a_party: side_a, side_b_party: side_b), party: party }
  end

  # The raw number behind #poll_margin — side A's best result minus side B's,
  # before any house-effect adjustment. nil when the poll never asked about
  # one of the two sides.
  def poll_margin_value(poll, race)
    side_a, side_b = race_sides(race)
    a = poll.poll_results.filter_map { |result| result.pct if result.party == side_a }.max
    b = poll.poll_results.filter_map { |result| result.pct if result.party == side_b }.max
    return nil if a.nil? || b.nil?

    a - b
  end

  # What the model did to this poll's margin, or nil when it did nothing.
  # `effects` is HouseEffect.applied_lookup for the run on show, so a poll
  # whose pollster was under the minimum (or whose effect was never estimated)
  # simply reports no adjustment rather than an adjustment of zero.
  #
  # Sign: a positive effect means the pollster leans Democratic and the model
  # subtracts it, so the adjusted margin is the raw margin MINUS the effect.
  def poll_adjustment(poll, race, effects)
    effect = effects[poll.pollster_id]
    return nil if effect.nil?

    raw = poll_margin_value(poll, race)
    return nil if raw.nil?

    side_a, side_b = race_sides(race)
    {
      effect: Site::Format.house_effect(effect),
      adjusted: Site::Format.margin(raw - effect, side_a_party: side_a, side_b_party: side_b),
      adjusted_party: margin_party(race, raw - effect)
    }
  end

  # Lowercase, whitespace-joined text for the /senate and /house client-side
  # filters: matches on the race's own display name (state name + office for
  # Senate, state code + district for House), the full state name, the bare
  # state code, the district number and — because a reader might type
  # exactly this — the word "special" for a special election. So "ny",
  # "new york", "17" and "ny-17" all find NY-17, and "georgia", "ga" or
  # "special" all find the Georgia Senate race.
  def race_search_text(race)
    parts = [ race.name, Race::STATE_NAMES[race.state], race.state, race.district ]
    parts << "special" if race.special?
    parts.compact.join(" ").downcase
  end

  # A /senate or /house column header that links to itself sorted the other
  # way when already active, and to ascending when it isn't — plain
  # query-param sorting, no JS table library. base_path/testid_prefix are
  # what keep this chamber-neutral: callers hand over their own path helper
  # and a short prefix rather than this helper knowing either chamber's name.
  #
  # Every link also carries data-table-filter-target="sortLink" so the
  # table-filter Stimulus controller can rewrite its href with the reader's
  # live search text before it navigates — see table_filter_controller.js
  # for why that has to happen client-side rather than here.
  def sort_header(label, key, base_path:, testid_prefix:, current_sort:, current_direction:)
    active = current_sort == key
    next_direction = active && current_direction == "asc" ? "desc" : "asc"
    indicator = active ? (current_direction == "asc" ? " ▲" : " ▼") : ""
    classes = active ? "font-semibold text-slate-900" : "text-slate-500 hover:text-slate-700"
    href = "#{base_path}?#{{ sort: key, dir: next_direction }.to_query}"

    link_to "#{label}#{indicator}", href, class: classes,
            data: { testid: "#{testid_prefix}-sort-#{key}", table_filter_target: "sortLink" }
  end

  private
    def win_probabilities(forecast)
      { "dem" => forecast.p_dem_win, "rep" => forecast.p_rep_win, "other" => forecast.p_other_win }
    end
end
