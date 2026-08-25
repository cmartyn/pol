namespace :pol do
  desc "Build the 2026 race board: Senate races from the verified list, 435 House districts with 2024 baselines, presidential leans"
  task seed_races: :environment do
    summary = Ingest::SeedRaces.new.call

    puts
    puts "  Race board (#{Ingest::Sources.cycle})"
    puts "  " + "-" * 46
    printf("  %-28s %16d\n", "Senate races", summary.senate)
    printf("  %-28s %16d\n", "  of which specials", summary.specials)
    printf("  %-28s %16d\n", "  with presidential lean", summary.leans)
    printf("  %-28s %16d\n", "House districts", summary.house)
    printf("  %-28s %15d%%\n", "  imputed baselines",
           summary.house.zero? ? 0 : (100.0 * summary.imputed / summary.house).round)
    printf("  %-28s %16d\n", "  imputed count", summary.imputed)
    puts "  " + "-" * 46
    puts "  Imputed: #{summary.imputed_districts.join(', ')}" if summary.imputed_districts.any?
    summary.warnings.each { |warning| puts "  WARNING: #{warning}" }
    puts
  end

  desc "Scrape every Wikipedia poll source once and ingest new polls"
  task scrape: :environment do
    outcomes = Ingest::Scraper.new.call

    puts
    # Wide enough for the longest source title there is — "2026 United States
    # House of Representatives elections in North Carolina" — because every
    # state House page shares its first 52 characters and a narrower column
    # turns thirty-three of them into the same row.
    printf("  %-72s %-10s %6s %5s %5s %5s %5s\n", "Source", "Status", "Rows", "New", "Dup", "Skip", "Ref")
    puts "  " + "-" * 114
    outcomes.each do |outcome|
      printf("  %-72s %-10s %6d %5d %5d %5d %5d\n", outcome.source.truncate(72), outcome.status,
             outcome.fetched, outcome.created, outcome.duplicate, outcome.skipped, outcome.refused)
      # When rows were skipped the Skip column already says so; anything else
      # (a missing page, a fetch that failed outright) needs spelling out.
      puts "      #{outcome.error}" if outcome.error.present? && outcome.skipped.zero?
      # A refused table is only a number in the column above. Which tables, and
      # why, is the part that says whether a race just went dark.
      next if outcome.refusals.blank?

      puts "      refused: " + outcome.refusals.sort.map { |reason, count| "#{reason} ×#{count}" }.join(", ")
    end
    puts "  " + "-" * 114
    printf("  %-72s %-10s %6d %5d %5d %5d %5d\n", "TOTAL (#{outcomes.size} sources)", "",
           outcomes.sum(&:fetched), outcomes.sum(&:created), outcomes.sum(&:duplicate),
           outcomes.sum(&:skipped), outcomes.sum(&:refused))
    failed = outcomes.count { |outcome| outcome.status == :failed }
    puts "  #{failed} source(s) failed outright" if failed.positive?

    reasons = outcomes.flat_map { |outcome| outcome.refusals.to_a }
                      .group_by(&:first).transform_values { |pairs| pairs.sum(&:last) }
    # The Ref column counts refused tables. `no_polling_section` is a page with
    # no table to refuse, so it is reported on its own line rather than leaving
    # an operator to work out why the two totals differ.
    empty_pages = reasons.delete(ScrapeRun::EMPTY_PAGE_REASON).to_i
    puts "  Refusals by reason: " + reasons.sort.map { |reason, count| "#{reason} ×#{count}" }.join(", ") if reasons.any?
    if empty_pages.positive?
      puts "  #{empty_pages} source(s) had no polling section at all — no table to refuse, " \
           "so not counted in Ref"
    end
    puts
  end

  desc "Run the forecast model once and print the headline numbers"
  task model: :environment do
    previous = ModelRun.succeeded.latest.first
    runner = Forecast::Runner.new(trigger: :manual)

    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    begin
      run = runner.call
    rescue Forecast::Runner::AlreadyRunning => error
      # The manual path is not exempt from the concurrency guard: it inserts
      # against the same unique index as the job, so a run kicked off by hand
      # while an ingest run is in flight is refused rather than racing it.
      in_flight = ModelRun.running.first
      puts
      puts "  #{error.message} — run #{in_flight&.id} started #{in_flight&.started_at&.to_fs(:short)}."
      puts "  Try again once it finishes; a run takes a couple of seconds."
      puts
      next
    end
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

    puts
    printf("  Model run %d — %s in %.1fs (seed %d)\n", run.id, run.status, elapsed, run.rng_seed)
    puts "  " + "-" * 62

    # In production the runner logs a failure and returns rather than raising,
    # so the task has to notice for itself instead of formatting nils.
    unless run.succeeded?
      puts "  #{run.error_message}"
      puts
      next
    end

    printf("  %-30s %+30.2f\n", "Generic ballot (D−R)", runner.national_env)
    printf("  %-30s %30s\n", "  from", "#{runner.generic_ballot.poll_count} polls, W = " \
                                       "#{runner.generic_ballot.weight.round(2)}, " \
                                       "#{runner.generic_ballot.window_days}-day window")
    printf("  %-30s %30s\n", "Races forecast", "#{run.forecasts.count} " \
                                               "(#{Race.senate.count} senate, #{Race.house.count} house)")
    printf("  %-30s %30.4f\n", "Error inflation (t)", runner.simulation.time_multiplier)
    puts "  " + "-" * 62

    run.chamber_forecasts.order(:chamber).each do |chamber|
      neither = 1.0 - chamber.p_dem_control - chamber.p_rep_control
      printf("  %-10s D %5.1f%%   R %5.1f%%%s   mean D seats %6.1f\n",
             chamber.chamber.capitalize, 100 * chamber.p_dem_control, 100 * chamber.p_rep_control,
             neither > 0.0005 ? format("   neither %4.1f%%", 100 * neither) : " " * 16,
             chamber.mean_dem_seats)
    end
    puts "  " + "-" * 62
    # What travels with the two control numbers. Phase 10 replaced the single
    # national error with 538's own decomposition, so the old "read this as
    # several points softer" warning is gone; what is left is the one
    # component we still cannot build, and it is worth a line because both
    # figures lean the same way without it.
    printf("  Correlated error: national %.1f, division %.1f, state %.1f (total %.4f).\n",
           *%i[sigma_national sigma_regional sigma_state].map { |key| Pol::Params.fetch!(:error_model, key) },
           Math.sqrt(%i[sigma_national sigma_regional sigma_state]
                       .sum { |key| Pol::Params.fetch!(:error_model, key)**2 }))
    puts "  538's decomposition less their demographic-cluster term (4.5826),"
    puts "  which needs data we do not have — so both control figures are a"
    puts "  point or two firmer than a fuller model's. BUILD_NOTES Phase 10 §A."
    puts "  " + "-" * 62

    if previous
      movers = biggest_movers(run, previous)
      puts "  Biggest movers vs run #{previous.id} (#{previous.started_at.to_fs(:short)})"
      if movers.empty?
        puts "    nothing moved"
      else
        movers.each do |name, change, now|
          printf("    %-24s %+6.1f pts  →  D %5.1f%%\n", name, change, 100 * now)
        end
      end
    else
      puts "  No earlier run to compare against"
    end
    puts
  end

  desc "Write today's national brief now — the same code path the 07:00 cron runs"
  task brief: :environment do
    before = Dispatch.published.daily_brief.recent_first.first
    skips_before = NewsroomSkip.maximum(:id).to_i

    Newsroom::DailyBriefJob.perform_now

    dispatch = Dispatch.published.daily_brief.recent_first.first
    puts
    if dispatch && dispatch != before
      puts "  #{dispatch.headline}"
      puts "  #{dispatch.dek}"
      puts "  " + "-" * 74
      puts dispatch.body_markdown.each_line.map { |line| "  #{line}" }.join
      puts "  " + "-" * 74
      printf("  %-14s %s\n", "dispatch", "##{dispatch.id}")
      printf("  %-14s %s\n", "model", dispatch.model_slug)
      printf("  %-14s %s\n", "cited polls", dispatch.cited_poll_ids.inspect)
      printf("  %-14s %s\n", "words", dispatch.body_markdown.split(/\s+/).size)
    else
      skip = NewsroomSkip.where(id: (skips_before + 1)..).recent_first.first
      puts skip ? "  No brief written — #{skip.reason}: #{skip.detail}" : "  No brief written; see the log."
    end
    puts
  end

  # Build-time only: the parser tests run entirely off the committed fixtures,
  # and nothing in the suite touches the network.
  desc "Re-download the trimmed Wikipedia HTML fixtures the parser tests run against (ONLY=prefix to narrow)"
  task refresh_fixtures: :environment do
    require "nokogiri"

    directory = Rails.root.join("test/fixtures/files")
    client = Ingest::WikipediaClient.new

    fixtures = [
      { file: "senate_georgia.html",      title: "2026 United States Senate election in Georgia",          sections: /polling/i },
      { file: "senate_ohio_special.html", title: "2026 United States Senate special election in Ohio",     sections: /polling/i },
      { file: "senate_iowa.html",         title: "2026 United States Senate election in Iowa",             sections: /polling/i },
      { file: "senate_rhode_island.html", title: "2026 United States Senate election in Rhode Island",     sections: /polling/i },
      # The generic-ballot table runs to 561 rows and the House page to 435
      # districts; both are capped so the fixtures stay a sane size. Everything
      # the parsers have to cope with survives the cut.
      { file: "generic_ballot.html",      title: Ingest::Sources.generic_ballot_title,                     sections: /\Apolling\z/i, max_rows: 45 },
      # Minnesota and North Dakota are in the list because they are the only
      # two states whose Democrats are not labelled "Democratic" on the page
      # (DFL and Democratic-NPL). Without them the fixture cannot catch a
      # party-label regression, which is exactly how eight Minnesota districts
      # once ended up with fabricated baselines.
      { file: "house_results_2024.html",  title: Ingest::Sources::HOUSE_RESULTS_TITLE,                     sections: /\A(Alabama|Alaska|Louisiana|Minnesota|North Dakota|Washington)\z/ },
      { file: "presidential_2024.html",   title: Ingest::Sources::PRESIDENTIAL_TITLES.fetch(2024),         sections: /results by state/i },
      { file: "presidential_2020.html",   title: Ingest::Sources::PRESIDENTIAL_TITLES.fetch(2020),         sections: /results by state/i },
      # State House pages, Phase 8. These are trimmed differently: a district
      # page's tables mean nothing without the "District 7 > General election >
      # Polling" nesting around them, so whole district sections are kept and
      # everything inside them that is not a polling table is thrown away.
      # Between them the six carry every refusal reason the parser can emit.
      { file: "house_michigan.html",       title: district_title("MI"), districts: /\ADistrict (4|7|10)\z/ },
      # Washington runs a top-two primary, so its primary tables carry party
      # tags and are the case a structural check has to catch.
      { file: "house_washington.html",     title: district_title("WA"), districts: /\ADistrict (3|4|5)\z/ },
      # Alaska is a single at-large district (singular title, no District
      # heading to read) and carries two "Generic Democrat" matchups.
      { file: "house_alaska.html",         title: district_title("AK", single: true), districts: /\A(Primary|General) election\z/ },
      # California's 22nd files its primary *results* under the Polling
      # heading, and its 11th is a Democrat-versus-Democrat general.
      { file: "house_california.html",     title: district_title("CA"), districts: /\ADistrict (11|22|48)\z/ },
      # North Carolina polls its congressional vote statewide, under no
      # district at all.
      { file: "house_north_carolina.html", title: district_title("NC"), districts: /\A(Statewide polling|District 1)\z/ },
      # Minnesota and Massachusetts are here for HouseCandidatesParser rather
      # than for polling. Minnesota is the settled case with the party label
      # that has bitten this codebase before — its Democrats are "Democratic
      # (DFL)" in every infobox — and its 2nd district is the open seat whose
      # incumbent is not on the ballot, so the fixture carries an incumbent
      # nominee and a non-incumbent one. Massachusetts votes in September, so
      # on an August page every one of its districts is still "TBD" or
      # "(presumptive)": the unsettled shape the parser has to refuse. Neither
      # state's kept sections hold a polling table, so what survives the trim
      # is the district infoboxes and little else.
      { file: "house_minnesota.html",      title: district_title("MN"), districts: /\ADistrict (1|2)\z/ },
      { file: "house_massachusetts.html",  title: district_title("MA"), districts: /\ADistrict (1|3)\z/ },
      # The two worst matchup tangles on the board: Maine's 2nd runs four
      # different Democrats against Paul LePage across thirteen polls, and
      # Florida's 25th has four polls and four matchups.
      { file: "house_maine.html",          title: district_title("ME"), districts: /\ADistrict 2\z/ },
      # Florida's 10th and 26th are here for the candidate parser and carry no
      # polling at all: the 10th is the uncontested case, a field of one marked
      # "(Uncontested)" whose infobox has swapped its Incumbent line for the
      # after-the-fact "before election" wording, and the 26th spells its
      # incumbent "Mario Diaz-Balart" against a nominee spelled "Mario
      # Díaz-Balart", which is what an incumbent check has to survive.
      { file: "house_florida.html",        title: district_title("FL"), districts: /\ADistrict (10|25|26)\z/ },
      # Delaware's page has no polling section of any kind — and does have
      # fundraising and ratings tables, which is the point: those must not be
      # counted as tables we refused.
      { file: "house_delaware.html",       title: district_title("DE", single: true), sections: /\A(Republican primary|General election)\z/ }
    ]

    only = ENV["ONLY"].presence
    fixtures = fixtures.select { |fixture| fixture[:file].include?(only) } if only

    total = 0
    fixtures.each do |fixture|
      html = client.page_html(fixture[:title])
      trimmed =
        if fixture[:districts]
          trim_district_sections(html, fixture[:districts])
        else
          trim_sections(html, fixture[:sections], max_rows: fixture[:max_rows])
        end
      path = directory.join(fixture[:file])
      path.write(trimmed)
      total += trimmed.bytesize
      printf("  %-30s %8.1f KB  %s\n", fixture[:file], trimmed.bytesize / 1024.0, fixture[:title])
    end
    printf("  %-30s %8.1f KB\n", "total", total / 1024.0)
    puts "  (poll_table_malformed.html and house_candidates_malformed.html are hand-edited " \
         "and are not refreshed here)"
  end
end

def district_title(state, single: false)
  Ingest::Sources.district_title(state, single_district: single)
end

# The races whose Democratic win probability moved most between two runs,
# reported in percentage points. Ten is enough to see a wave forming without
# printing 470 lines. The noise floor is site.movers_floor_pp — the same one
# the dashboard's Movers module uses — so the rake task and the site agree on
# what "moved" means rather than each carrying its own cutoff.
def biggest_movers(run, previous, limit: 10)
  before = previous.forecasts.pluck(:race_id, :p_dem_win).to_h
  names = Race.where(id: before.keys).pluck(:id, :state, :district, :office).to_h do |id, state, district, office|
    [ id, office == "house" ? "#{state}-#{format('%02d', district)}" : "#{state} #{office.capitalize}" ]
  end
  floor_pp = Pol::Params.fetch!(:site, :movers_floor_pp)

  run.forecasts
     .where(race_id: before.keys)
     .pluck(:race_id, :p_dem_win)
     .map { |race_id, now| [ names[race_id], 100 * (now - before[race_id]), now ] }
     .reject { |_, change, _| change.abs < floor_pp }
     .sort_by { |_, change, _| -change.abs }
     .first(limit)
end

# Same idea as trim_sections, for a state House page. The difference is what
# has to survive: a district's polling tables are only interpretable inside
# their "District 7 > General election > Polling" nesting, so whole district
# sections are kept and gutted from the inside — nested sections holding no
# polling table go, and inside the ones that stay only headings, sections and
# polling tables are left. A 5 MB page comes out at a few dozen KB with every
# structure the parser reads still standing.
def trim_district_sections(html, pattern)
  document = Nokogiri::HTML5(html)

  sections = document.css("section").select do |section|
    heading = section.at_css("h1,h2,h3,h4,h5")
    heading && heading.text.strip.match?(pattern)
  end
  sections = sections.reject { |section| sections.any? { |other| other != section && section.ancestors.include?(other) } }

  polling = ->(node) { node.ancestors("section").any? { |s| s.at_css("h1,h2,h3,h4,h5")&.text.to_s.match?(/\bpoll/i) } }

  sections.each do |section|
    section.css("section").each { |nested| nested.remove if nested.css("table.wikitable").none?(&polling) }
    boxes = election_infoboxes(section)
    section.css("p, ul, ol, dl, figure, style, link, blockquote, table").each do |node|
      next if node.name == "table" && node["class"].to_s.split.include?("wikitable") && polling.call(node)
      next if inside_kept_infobox?(node, boxes)

      node.remove
    end
    section.css("div").each do |node|
      next if inside_kept_infobox?(node, boxes)

      node.remove if node.css("table.wikitable").empty?
    end
  end

  wrap_fixture(sections, lead_infoboxes(document))
end

# Keeps only the <section> elements whose heading matches, which is what turns a
# multi-megabyte Parsoid document into a fixture: infoboxes, navboxes, images and
# references all go, and the section/heading structure the parsers rely on stays.
#
# Enclosing sections stay too, stripped to their headings. A Georgia "Polling"
# section lifted out of its "Republican primary" parent stops being a primary
# table as far as the parser can tell — the fixture then agrees with the live
# page about how many tables are refused and disagrees about why, which is the
# worst kind of fixture: one that passes for the wrong reason.
def trim_sections(html, pattern, max_rows: nil)
  document = Nokogiri::HTML5(html)

  matched = document.css("section").select do |section|
    heading = section.at_css("h1,h2,h3,h4,h5")
    heading && heading.text.strip.match?(pattern)
  end
  matched = matched.reject { |section| matched.any? { |other| other != section && section.ancestors.include?(other) } }

  ancestors = matched.flat_map { |section| section.ancestors("section").to_a }.uniq - matched
  kept = matched + ancestors

  # Lifted out before the sweep below deletes the lead section they live in.
  lead = lead_infoboxes(document)
  document.css("section").to_a.each { |section| section.remove unless kept.include?(section) }
  # An ancestor is scaffolding: its heading is what a nested table's context is
  # read from, and everything else it holds belongs to some other subsection.
  ancestors.each do |section|
    section.element_children.each do |child|
      child.remove unless child.name == "section" || child.name.match?(/\Ah[1-6]\z/)
    end
  end

  if max_rows
    matched.each do |section|
      section.css("table.wikitable").each { |table| table.css("tr").drop(max_rows + 1).each(&:remove) }
    end
  end

  # The outermost survivors: every section still standing is one we kept, so a
  # section with no section above it is the root of a chain worth emitting.
  wrap_fixture(kept.reject { |section| section.ancestors("section").any? }, lead)
end

# A district's election infobox — the "Nominee / Party / Incumbent" box at the
# top of a "District 7" section, and the only place on these pages that states
# the general-election field in one shape every state uses. Identified by the
# parser's own field-row pattern rather than by the ib-election class, so that
# the trim cannot start keeping a different set of boxes than
# Ingest::HouseCandidatesParser reads.
def election_infoboxes(node)
  node.css("table.infobox").select do |table|
    table.css("th").any? { |th| th.text.strip.match?(Ingest::HouseCandidatesParser::FIELD_ROW) }
  end
end

# An infobox is kept whole, and the ordinary strip rules must not reach inside
# it: the incumbent's name sits in a <p>, and the Nominee and Party rows sit in
# a <table> nested in the box, so both would otherwise be thrown away and the
# box left saying nothing.
def inside_kept_infobox?(node, boxes)
  boxes.any? { |box| box == node || node.ancestors.include?(box) }
end

# On a state with a single at-large district there are no "District N" sections
# to keep, and the one infobox sits in the lead — section 0, which has no
# heading and so matches no fixture pattern. Emitted alongside the kept
# sections, in a heading-less section of its own, so the fixture reproduces the
# live page's "infobox under no district heading" shape rather than inventing a
# district heading the parser would then read.
#
# "In the lead" is what the heading test means: on a fifty-district page every
# district's infobox is in a section of its own, and the ones whose section was
# trimmed away must stay trimmed away rather than pile up here.
def lead_infoboxes(document)
  election_infoboxes(document).reject do |box|
    box.ancestors("section").any? { |section| section.at_css("h1,h2,h3,h4,h5") }
  end
end

def wrap_fixture(sections, lead = [])
  <<~HTML
    <html><head><meta charset="utf-8"><title>pol test fixture</title></head>
    <body>
    #{lead.map { |box| "<section>#{box.to_html}</section>" }.join("\n")}
    #{sections.map(&:to_html).join("\n")}
    </body></html>
  HTML
end
