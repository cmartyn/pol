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
    printf("  %-58s %-10s %6s %5s %5s %5s\n", "Source", "Status", "Rows", "New", "Dup", "Skip")
    puts "  " + "-" * 94
    outcomes.each do |outcome|
      printf("  %-58s %-10s %6d %5d %5d %5d\n", outcome.source.truncate(58), outcome.status,
             outcome.fetched, outcome.created, outcome.duplicate, outcome.skipped)
      # When rows were skipped the Skip column already says so; anything else
      # (a missing page, a fetch that failed outright) needs spelling out.
      puts "      #{outcome.error}" if outcome.error.present? && outcome.skipped.zero?
    end
    puts "  " + "-" * 94
    printf("  %-58s %-10s %6d %5d %5d %5d\n", "TOTAL (#{outcomes.size} sources)", "",
           outcomes.sum(&:fetched), outcomes.sum(&:created), outcomes.sum(&:duplicate), outcomes.sum(&:skipped))
    failed = outcomes.count { |outcome| outcome.status == :failed }
    puts "  #{failed} source(s) failed outright" if failed.positive?
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
    # The number does not travel without this. v1 correlates races through one
    # national error where 538 uses four, so the House seat distribution is too
    # narrow and its control probability is too confident — measured at 96.3%
    # here against 83.9% at 538's correlated total.
    puts "  Read House control as several points softer than printed: v1 has one"
    puts "  correlated error term where 538 has four, which overstates certainty"
    puts "  in whichever party leads (~96% here reads ~84% at 538's correlated"
    puts "  total). Senate is affected too, by roughly 7 points. BUILD_NOTES §A4."
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

  # Build-time only: the parser tests run entirely off the committed fixtures,
  # and nothing in the suite touches the network.
  desc "Re-download the trimmed Wikipedia HTML fixtures the parser tests run against"
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
      { file: "presidential_2020.html",   title: Ingest::Sources::PRESIDENTIAL_TITLES.fetch(2020),         sections: /results by state/i }
    ]

    total = 0
    fixtures.each do |fixture|
      trimmed = trim_sections(client.page_html(fixture[:title]), fixture[:sections], max_rows: fixture[:max_rows])
      path = directory.join(fixture[:file])
      path.write(trimmed)
      total += trimmed.bytesize
      printf("  %-30s %8.1f KB  %s\n", fixture[:file], trimmed.bytesize / 1024.0, fixture[:title])
    end
    printf("  %-30s %8.1f KB\n", "total", total / 1024.0)
    puts "  (poll_table_malformed.html is hand-edited and is not refreshed here)"
  end
end

# The races whose Democratic win probability moved most between two runs,
# reported in percentage points. Ten is enough to see a wave forming without
# printing 470 lines.
def biggest_movers(run, previous, limit: 10)
  before = previous.forecasts.pluck(:race_id, :p_dem_win).to_h
  names = Race.where(id: before.keys).pluck(:id, :state, :district, :office).to_h do |id, state, district, office|
    [ id, office == "house" ? "#{state}-#{format('%02d', district)}" : "#{state} #{office.capitalize}" ]
  end

  run.forecasts
     .where(race_id: before.keys)
     .pluck(:race_id, :p_dem_win)
     .map { |race_id, now| [ names[race_id], 100 * (now - before[race_id]), now ] }
     .reject { |_, change, _| change.abs < 0.05 }
     .sort_by { |_, change, _| -change.abs }
     .first(limit)
end

# Keeps only the <section> elements whose heading matches, which is what turns a
# multi-megabyte Parsoid document into a fixture: infoboxes, navboxes, images and
# references all go, and the section/heading structure the parsers rely on stays.
def trim_sections(html, pattern, max_rows: nil)
  document = Nokogiri::HTML5(html)

  sections = document.css("section").select do |section|
    heading = section.at_css("h1,h2,h3,h4,h5")
    heading && heading.text.strip.match?(pattern)
  end
  sections = sections.reject { |section| sections.any? { |other| other != section && section.ancestors.include?(other) } }

  if max_rows
    sections.each do |section|
      section.css("table.wikitable").each { |table| table.css("tr").drop(max_rows + 1).each(&:remove) }
    end
  end

  <<~HTML
    <html><head><meta charset="utf-8"><title>pol test fixture</title></head>
    <body>
    #{sections.map(&:to_html).join("\n")}
    </body></html>
  HTML
end
