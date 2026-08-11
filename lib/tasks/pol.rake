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
      { file: "house_results_2024.html",  title: Ingest::Sources::HOUSE_RESULTS_TITLE,                     sections: /\A(Alabama|Alaska|Louisiana|Washington)\z/ },
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
