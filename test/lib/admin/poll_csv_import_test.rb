require "test_helper"

class Admin::PollCsvImportTest < ActiveSupport::TestCase
  HEADER = "race_slug,pollster,field_start,field_end,sample_size,population,sponsor,source_url," \
           "dem_pct,rep_pct,ind_pct,other_pct,dem_candidate,rep_candidate,ind_candidate".freeze

  def csv(*rows)
    ([ HEADER ] + rows).join("\n") + "\n"
  end

  test "a valid row is created through Ingest::RecordPoll with entry_mode csv" do
    row = "#{races(:senate_maine).slug},Harbor Analytics,2026-08-01,2026-08-04,700,lv,Portland Press," \
          "https://example.com/harbor-1,48.0,44.5,,,,,"

    result = Admin::PollCsvImport.call(csv(row))

    assert_equal 1, result.size
    assert result.first.created?
    assert_equal 2, result.first.line_number
    poll = result.first.poll
    assert_equal "csv", poll.entry_mode
    assert_equal races(:senate_maine), poll.race
    assert_equal [ 44.5, 48.0 ], poll.poll_results.map(&:pct).sort
  end

  test "a blank race_slug creates a generic-ballot poll" do
    row = ",Delta Metrics,,2026-08-01,1200,lv,,https://example.com/delta-1,46.5,44.5,,,,,"

    result = Admin::PollCsvImport.call(csv(row))

    assert result.first.created?
    assert_nil result.first.poll.race_id
  end

  test "an unknown race_slug rejects the row without raising" do
    row = "not-a-real-race,Harbor Analytics,,2026-08-04,700,lv,,https://example.com/harbor-2,48.0,44.5,,,,,"

    result = Admin::PollCsvImport.call(csv(row))

    assert result.first.invalid?
    assert_match(/race_slug/, result.first.message)
  end

  test "an unrecognized population value rejects the row without raising ArgumentError" do
    row = "#{races(:senate_maine).slug},Harbor Analytics,,2026-08-04,700,likely,,https://example.com/harbor-3,48.0,44.5,,,,,"

    result = Admin::PollCsvImport.call(csv(row))

    assert result.first.invalid?
    assert_match(/population/, result.first.message)
  end

  test "population is case-insensitive" do
    row = "#{races(:senate_maine).slug},Harbor Analytics,,2026-08-04,700,LV,,https://example.com/harbor-4,48.0,44.5,,,,,"

    result = Admin::PollCsvImport.call(csv(row))

    assert result.first.created?
    assert_equal "lv", result.first.poll.population
  end

  test "a non-numeric percentage rejects the row rather than silently recording zero" do
    row = "#{races(:senate_maine).slug},Harbor Analytics,,2026-08-04,700,lv,,https://example.com/harbor-5,N/A,44.5,,,,,"

    assert_no_difference [ "Poll.count", "PollResult.count" ] do
      @result = Admin::PollCsvImport.call(csv(row))
    end

    assert @result.first.invalid?
  end

  test "a missing source_url rejects the row (RecordPoll's own validation)" do
    row = "#{races(:senate_maine).slug},Harbor Analytics,,2026-08-04,700,lv,,,48.0,44.5,,,,,"

    result = Admin::PollCsvImport.call(csv(row))

    assert result.first.invalid?
    assert_match(/source_url/, result.first.message)
  end

  test "candidate columns resolve by name within the row's race" do
    row = "#{races(:senate_maine).slug},Harbor Analytics,,2026-08-04,700,lv,," \
          "https://example.com/harbor-6,48.0,44.5,,,#{candidates(:maine_dem).name},#{candidates(:maine_rep).name},"

    result = Admin::PollCsvImport.call(csv(row))

    poll = result.first.poll
    assert_equal candidates(:maine_dem), poll.poll_results.find_by(party: :dem).candidate
    assert_equal candidates(:maine_rep), poll.poll_results.find_by(party: :rep).candidate
  end

  test "an unmatched candidate name leaves the result's candidate blank rather than rejecting the row" do
    row = "#{races(:senate_maine).slug},Harbor Analytics,,2026-08-04,700,lv,," \
          "https://example.com/harbor-7,48.0,44.5,,,Nobody Real,,"

    result = Admin::PollCsvImport.call(csv(row))

    assert result.first.created?
    assert_nil result.first.poll.poll_results.find_by(party: :dem).candidate
  end

  test "ind_pct and other_pct are optional result columns" do
    row = "#{races(:senate_maine).slug},Harbor Analytics,,2026-08-04,700,lv,," \
          "https://example.com/harbor-8,40.0,38.0,15.0,2.0,,,"

    result = Admin::PollCsvImport.call(csv(row))

    assert_equal %w[dem ind other rep], result.first.poll.poll_results.map(&:party).sort
  end

  test "line numbers count the header as line 1, so the first data row is line 2" do
    rows = 3.times.map { |i| "#{races(:senate_maine).slug},Pollster #{i},,2026-08-0#{i + 1},700,lv,,https://example.com/p#{i},48.0,44.0,,,,," }

    result = Admin::PollCsvImport.call(csv(*rows))

    assert_equal [ 2, 3, 4 ], result.map(&:line_number)
  end

  test "a repeated row within the same file is created once and a duplicate thereafter" do
    row = "#{races(:senate_maine).slug},Harbor Analytics,,2026-08-04,700,lv,,https://example.com/harbor-9,48.0,44.5,,,,,"

    result = Admin::PollCsvImport.call(csv(row, row))

    assert result.first.created?
    assert result.second.duplicate?
  end

  test "one invalid row does not stop the rest of the file from being processed (per-row outcomes, not whole-file transactionality)" do
    good_one = "#{races(:senate_maine).slug},Harbor Analytics,,2026-08-01,700,lv,,https://example.com/mixed-1,48.0,44.0,,,,,"
    bad = ",Broken Row,,2026-08-02,700,lv,,,48.0,44.0,,,,," # missing source_url
    good_two = "#{races(:senate_maine).slug},Cardinal Research,,2026-08-03,650,rv,,https://example.com/mixed-2,46.0,45.0,,,,,"

    assert_difference "Poll.count", 2 do
      result = Admin::PollCsvImport.call(csv(good_one, bad, good_two))

      assert_equal %i[created invalid created], result.map(&:status)
    end
  end

  test "touches the race for each newly created poll's race, once per race" do
    races(:senate_maine).update_column(:updated_at, 1.day.ago)
    row_a = "#{races(:senate_maine).slug},Harbor Analytics,,2026-08-01,700,lv,,https://example.com/touch-1,48.0,44.0,,,,,"
    row_b = "#{races(:senate_maine).slug},Cardinal Research,,2026-08-02,700,lv,,https://example.com/touch-2,46.0,45.0,,,,,"

    Admin::PollCsvImport.call(csv(row_a, row_b))

    assert races(:senate_maine).reload.updated_at > 23.hours.ago
  end

  test "a generic-ballot row touches nothing" do
    max_before = Race.maximum(:updated_at)
    row = ",Delta Metrics,,2026-08-01,1200,lv,,https://example.com/gb-touch,46.5,44.5,,,,,"

    Admin::PollCsvImport.call(csv(row))

    assert_equal max_before, Race.maximum(:updated_at)
  end

  test "an empty file produces no rows" do
    assert_equal [], Admin::PollCsvImport.call("")
  end
end
